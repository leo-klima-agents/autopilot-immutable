// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase} from "../utils/TestBase.sol";
import {EpochPilot} from "../../src/EpochPilot.sol";
import {IVoter} from "../../src/interfaces/IVoter.sol";
import {IVotingEscrow} from "../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

interface IERC20Meta is IERC20 {
    function symbol() external view returns (string memory);
    function minter() external view returns (address);
}

interface IMinter {
    function voter() external view returns (address);
}

interface IVoterEnum {
    function pools(uint256 i) external view returns (address);
    function length() external view returns (uint256);
}

interface IPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @title Full EpochPilot lifecycle against the live protocol on a Base fork:
///        deposit → activate → mirror revote → revenue claim → rebase claim →
///        term expiry → unwind → redeem.
contract EpochPilotForkTest is TestBase {
    address constant AERO_TOKEN = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    uint256 constant WEEK = 7 days;
    /// @dev Pinned for determinism and RPC-cache reuse; override with BASE_FORK_BLOCK.
    uint256 constant FORK_BLOCK = 49_016_010;

    IERC20Meta aero;
    IVoter voter;
    IVotingEscrow ve;
    EpochPilot pilot;
    bool skipAll;

    address alice = makeAddr("f_alice");
    address bob = makeAddr("f_bob");
    address keeper = makeAddr("f_keeper");

    function setUp() public {
        if (!vm.envExists("BASE_RPC_URL")) {
            skipAll = true;
            return;
        }
        vm.createSelectFork("base", vm.envOr("BASE_FORK_BLOCK", FORK_BLOCK));
        aero = IERC20Meta(AERO_TOKEN);
        assertEq(aero.symbol(), "AERO");
        voter = IVoter(IMinter(aero.minter()).voter());
        ve = IVotingEscrow(voter.ve());
        pilot = new EpochPilot(address(voter));

        vm.startPrank(address(ve)); // deepest AERO pool on Base
        aero.transfer(alice, 2_000e18);
        aero.transfer(bob, 2_000e18);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amt) internal {
        vm.startPrank(who);
        aero.approve(address(pilot), amt);
        pilot.deposit(amt);
        vm.stopPrank();
    }

    /// @dev Builds a mirror candidate set from the live pool index: read every
    ///      pool's weight, then greedily take the heaviest live-gauge pools
    ///      until coverage clears the vault's 80% threshold. This is exactly
    ///      the job a revote caller does off-chain.
    function _candidateSet() internal view returns (address[] memory pools, bool found) {
        uint256 total = voter.totalWeight();
        uint256 maxN = voter.maxVotingNum();
        uint256 n = IVoterEnum(address(voter)).length();

        address[] memory all = new address[](n);
        uint256[] memory w = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            all[i] = IVoterEnum(address(voter)).pools(i);
            w[i] = voter.weights(all[i]);
        }

        address[] memory picked = new address[](maxN);
        uint256 count;
        uint256 covered;
        while (count < maxN && covered * 10_000 < total * 8_000) {
            // extract-max
            uint256 maxIdx = type(uint256).max;
            uint256 maxW;
            for (uint256 i; i < n; ++i) {
                if (w[i] > maxW) {
                    maxW = w[i];
                    maxIdx = i;
                }
            }
            if (maxIdx == type(uint256).max) break; // exhausted
            w[maxIdx] = 0; // consume
            address g = voter.gauges(all[maxIdx]);
            if (g == address(0) || !voter.isAlive(g)) continue; // dead gauge: skip
            picked[count++] = all[maxIdx];
            covered += maxW;
        }
        if (covered * 10_000 < total * 8_000) return (pools, false);
        pools = new address[](count);
        for (uint256 i; i < count; ++i) {
            pools[i] = picked[i];
        }
        found = true;
    }

    function _warpToRevoteWindow() internal {
        vm.warp(voter.epochNext(block.timestamp) - 3 hours);
    }

    function test_fork_lifecycle_depositThroughRedeem() public {
        if (skipAll) return vm.skip(true);

        // ── seed + activate ──────────────────────────────────────────────────
        _deposit(alice, 600e18);
        _deposit(bob, 400e18);
        pilot.activate();
        uint256 id = pilot.tokenId();
        assertEq(ve.ownerOf(id), address(pilot));
        assertEq(uint256(uint128(ve.locked(id).amount)), 1_000e18);
        assertEq(pilot.lockEnd() % WEEK, 0);
        assertFalse(ve.locked(id).isPermanent);

        // ── post-activation deposit joins the lock pro-rata ─────────────────
        _deposit(alice, 100e18);
        assertEq(uint256(uint128(ve.locked(id).amount)), 1_100e18);

        // ── mirror revote inside the window ──────────────────────────────────
        (address[] memory pools, bool found) = _candidateSet();
        if (!found) return vm.skip(true); // coverage unreachable in scanned prefix at this block
        _warpToRevoteWindow();
        vm.prank(keeper);
        pilot.revote(pools);
        assertGt(voter.usedWeights(id), 0, "vote landed");
        // window is enforced: a second call this epoch dies at the protocol
        vm.expectRevert();
        pilot.revote(pools);

        // ── revenue claim: registry-validated targets, zero-delta tolerant ──
        address gauge = voter.gauges(pools[0]);
        address[] memory gs = new address[](1);
        gs[0] = gauge;
        address[][] memory feeToks = new address[][](1);
        feeToks[0] = new address[](2);
        feeToks[0][0] = IPool(pools[0]).token0();
        feeToks[0][1] = IPool(pools[0]).token1();
        address[][] memory bribeToks = new address[][](1);
        bribeToks[0] = new address[](1);
        bribeToks[0][0] = AERO_TOKEN;
        vm.prank(keeper);
        pilot.claimRevenue(gs, feeToks, bribeToks); // fresh vote → 0 earned; must not revert

        // ── rebase claim (0 pending on a fresh lock; must not revert) ────────
        vm.prank(keeper);
        pilot.claimRebase();

        // ── compound with nothing loose fails loudly ─────────────────────────
        if (aero.balanceOf(address(pilot)) == 0) {
            vm.expectRevert(EpochPilot.NothingToCompound.selector);
            pilot.compound();
        }

        // ── term end: unwind + redeem ────────────────────────────────────────
        vm.warp(pilot.lockEnd() + pilot.UNWIND_GRACE() + 2 hours);
        pilot.unwind();
        assertTrue(pilot.unwound());
        uint256 poolBal = aero.balanceOf(address(pilot));
        assertGe(poolBal, 1_100e18, "principal came home");

        uint256 aliceShares = pilot.balanceOf(alice);
        uint256 total = pilot.totalShares();
        uint256 before = aero.balanceOf(alice);
        vm.prank(alice);
        uint256 got = pilot.redeem(aliceShares);
        assertEq(got, poolBal * aliceShares / total);
        assertEq(aero.balanceOf(alice) - before, got);
    }

    function test_fork_revote_rejectsLowCoverageSubset() public {
        if (skipAll) return vm.skip(true);
        _deposit(alice, 600e18);
        pilot.activate();
        // one live pool alone cannot clear 80% of total weight
        address one;
        for (uint256 i; i < 50; ++i) {
            address p = IVoterEnum(address(voter)).pools(i);
            address g = voter.gauges(p);
            if (g != address(0) && voter.isAlive(g) && voter.weights(p) > 0) {
                one = p;
                break;
            }
        }
        if (one == address(0) || voter.weights(one) * 10_000 >= voter.totalWeight() * 8_000) {
            return vm.skip(true);
        }
        _warpToRevoteWindow();
        address[] memory pools = new address[](1);
        pools[0] = one;
        vm.expectRevert(EpochPilot.CoverageTooLow.selector);
        pilot.revote(pools);
    }

    function test_fork_zeroAdminSurface_probeStateChangers() public {
        if (skipAll) return vm.skip(true);
        // No function on the ABI is caller-gated except by arithmetic: probe
        // the mutating surface from a fresh EOA and require that any revert
        // is a typed phase/validation error, never an owner check. (The full
        // guarantee is by construction: the source has zero onlyX modifiers
        // and no owner storage — asserted by scripts/banned-constructs.sh.)
        address stranger = makeAddr("stranger2");
        vm.startPrank(stranger);
        vm.expectRevert(EpochPilot.BelowMinimum.selector); // not an auth error
        pilot.activate();
        vm.expectRevert(EpochPilot.NotActive.selector);
        pilot.compound();
        vm.expectRevert(EpochPilot.NotActive.selector);
        pilot.claimRebase();
        vm.expectRevert(EpochPilot.NotActive.selector);
        pilot.unwind();
        vm.stopPrank();
    }
}
