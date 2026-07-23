// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase} from "../utils/TestBase.sol";
import {IVoter} from "../../src/interfaces/IVoter.sol";
import {IVotingEscrow} from "../../src/interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

interface IERC20Meta is IERC20 {
    function symbol() external view returns (string memory);
    function minter() external view returns (address);
}

interface IMinter {
    function voter() external view returns (address);
    function ve() external view returns (address);
    function rewardsDistributor() external view returns (address);
}

/// @title Empirical assertions of every load-bearing v2 fact (G9/G10, §2)
/// @dev   Run against a live Base mainnet fork. Addresses are NOT taken from
///        docs or articles: the only root of trust is the AERO token address,
///        whose identity is asserted by symbol, and every protocol contract
///        is resolved by walking the on-chain link graph from it
///        (AERO → minter → {voter, ve, rewardsDistributor}) and
///        cross-checking every back-reference. This mirrors exactly what the
///        EpochPilot constructor does from the Voter.
contract AerodromeFactsForkTest is TestBase {
    uint256 constant WEEK = 7 days;
    uint256 constant HOUR = 1 hours;

    /// @dev Root of trust; identity asserted in test_addressResolution.
    address constant AERO_TOKEN = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    /// @dev Pinned for determinism and RPC-cache reuse; override with BASE_FORK_BLOCK.
    uint256 constant FORK_BLOCK = 49_016_010;

    IERC20Meta aero;
    IMinter minter;
    IVoter voter;
    IVotingEscrow ve;
    IRewardsDistributor dist;
    bool skipAll;

    function setUp() public {
        if (!vm.envExists("BASE_RPC_URL")) {
            skipAll = true;
            return;
        }
        vm.createSelectFork("base", vm.envOr("BASE_FORK_BLOCK", FORK_BLOCK));
        aero = IERC20Meta(AERO_TOKEN);
        minter = IMinter(aero.minter());
        voter = IVoter(minter.voter());
        ve = IVotingEscrow(minter.ve());
        dist = IRewardsDistributor(IMinter(address(minter)).rewardsDistributor());
    }

    // ── address resolution: the link graph must be closed ────────────────────

    function test_fork_addressResolution_linkGraphClosed() public {
        if (skipAll) return vm.skip(true);
        assertEq(aero.symbol(), "AERO");
        assertEq(voter.ve(), address(ve));
        assertEq(ve.token(), AERO_TOKEN);
        assertEq(ve.distributor(), address(dist));
        assertEq(dist.ve(), address(ve));
        assertEq(block.chainid, 8453);
    }

    // ── G9: epoch arithmetic exposed by the Voter ────────────────────────────

    function test_fork_G9_epochWindows() public {
        if (skipAll) return vm.skip(true);
        uint256 t = block.timestamp;
        uint256 start = voter.epochStart(t);
        assertEq(start, t - (t % WEEK), "epochStart is week-floor");
        assertEq(voter.epochNext(t), start + WEEK);
        assertEq(voter.epochVoteStart(t), start + HOUR, "first hour is closed");
        assertEq(voter.epochVoteEnd(t), start + WEEK - HOUR, "last hour is whitelist-only");
    }

    /// @dev The launch docs said 30; live governance raised it. The vault
    ///      reads it live — this test just pins that it exists and is sane,
    ///      and records the live value in the diff log (docs/g-facts.md).
    function test_fork_G9_maxVotingNumLiveValue() public {
        if (skipAll) return vm.skip(true);
        uint256 n = voter.maxVotingNum();
        assertGe(n, 2);
        assertLe(n, 1_000);
    }

    function test_fork_G9_publicWeightsAndTotalWeight() public {
        if (skipAll) return vm.skip(true);
        assertGt(voter.totalWeight(), 0);
        (address pool,) = _firstLivePool(0);
        assertGt(voter.weights(pool), 0);
    }

    // ── G9: vote gates and normalization, exercised with a real lock ─────────

    function _fundAndLock(address who, uint256 amount) internal returns (uint256 id) {
        // the escrow itself is the deepest AERO pool on Base — borrow from it
        vm.prank(address(ve));
        aero.transfer(who, amount);
        vm.startPrank(who);
        aero.approve(address(ve), amount);
        id = ve.createLock(amount, 26 weeks);
        vm.stopPrank();
    }

    function _firstLivePool(uint256 fromIdx) internal view returns (address pool, uint256 idx) {
        for (uint256 i = fromIdx; i < fromIdx + 50; ++i) {
            address p = IVoterEnum(address(voter)).pools(i);
            address g = voter.gauges(p);
            if (g != address(0) && voter.isAlive(g) && voter.weights(p) > 0) return (p, i);
        }
        revert("no live pool found");
    }

    function _warpIntoOpenWindow() internal {
        uint256 t = block.timestamp;
        uint256 start = voter.epochStart(t);
        // safely inside (start+1h, start+WEEK-1h)
        if (t <= start + HOUR + 1 || t > start + WEEK - HOUR - 2 hours) {
            vm.warp(start + 3 days);
        }
    }

    function test_fork_G9_voteNormalizesRelativeWeights() public {
        if (skipAll) return vm.skip(true);
        _warpIntoOpenWindow();
        address user = makeAddr("voteUser");
        uint256 id = _fundAndLock(user, 1_000e18);
        (address poolA, uint256 i) = _firstLivePool(0);
        (address poolB,) = _firstLivePool(i + 1);

        address[] memory pools = new address[](2);
        pools[0] = poolA;
        pools[1] = poolB;
        uint256[] memory w = new uint256[](2);
        w[0] = 1;
        w[1] = 3;
        vm.prank(user);
        voter.vote(id, pools, w);

        uint256 va = voter.votes(id, poolA);
        uint256 vb = voter.votes(id, poolB);
        assertGt(va, 0);
        // relative weights normalized over the NFT's voting balance: 1:3
        assertApproxEqRel(vb, va * 3, 1e15);
        assertApproxEqAbs(voter.usedWeights(id), va + vb, 2);
        assertEq(voter.lastVoted(id), block.timestamp);
    }

    function test_fork_G9_onlyNewEpoch_oneVotePerEpoch() public {
        if (skipAll) return vm.skip(true);
        _warpIntoOpenWindow();
        address user = makeAddr("epochUser");
        uint256 id = _fundAndLock(user, 100e18);
        (address pool,) = _firstLivePool(0);
        address[] memory pools = new address[](1);
        pools[0] = pool;
        uint256[] memory w = new uint256[](1);
        w[0] = 1;
        vm.startPrank(user);
        voter.vote(id, pools, w);
        vm.expectRevert(); // AlreadyVotedOrDeposited
        voter.vote(id, pools, w);
        vm.stopPrank();
    }

    function test_fork_G9_distributeWindowBlocksFirstHour() public {
        if (skipAll) return vm.skip(true);
        _warpIntoOpenWindow();
        address user = makeAddr("windowUser");
        uint256 id = _fundAndLock(user, 100e18);
        (address pool,) = _firstLivePool(0);
        address[] memory pools = new address[](1);
        pools[0] = pool;
        uint256[] memory w = new uint256[](1);
        w[0] = 1;
        vm.warp(voter.epochNext(block.timestamp) + 30 minutes); // first hour of next epoch
        vm.prank(user);
        vm.expectRevert(); // DistributeWindow
        voter.vote(id, pools, w);
    }

    function test_fork_G9_lastHourIsWhitelistOnly() public {
        if (skipAll) return vm.skip(true);
        _warpIntoOpenWindow();
        address user = makeAddr("lateUser");
        uint256 id = _fundAndLock(user, 100e18);
        (address pool,) = _firstLivePool(0);
        address[] memory pools = new address[](1);
        pools[0] = pool;
        uint256[] memory w = new uint256[](1);
        w[0] = 1;
        vm.warp(voter.epochVoteEnd(block.timestamp) + 10 minutes); // inside final hour
        vm.prank(user);
        vm.expectRevert(); // NotWhitelistedNFT
        voter.vote(id, pools, w);
    }

    // ── G9: claim-target registries are on-chain ─────────────────────────────

    function test_fork_G9_gaugeRewardRegistries() public {
        if (skipAll) return vm.skip(true);
        (address pool,) = _firstLivePool(0);
        address gauge = voter.gauges(pool);
        assertTrue(voter.isGauge(gauge));
        assertTrue(voter.gaugeToFees(gauge) != address(0));
        assertTrue(voter.gaugeToBribe(gauge) != address(0));
        assertEq(voter.poolForGauge(gauge), pool);
    }

    // ── G10: rebase claims are permissionless and auto-compound ─────────────

    function test_fork_G10_rebasePermissionlessAutoCompounds() public {
        if (skipAll) return vm.skip(true);
        // find a live mainnet veNFT with a pending rebase and an unexpired lock
        uint256 id;
        for (uint256 i = 1; i <= 400; ++i) {
            if (dist.claimable(i) > 0 && ve.locked(i).end > block.timestamp) {
                id = i;
                break;
            }
        }
        if (id == 0) return vm.skip(true); // no candidate at this block — inconclusive, not false
        uint256 lockedBefore = uint256(uint128(ve.locked(id).amount));
        uint256 expect = dist.claimable(id);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        uint256 got = dist.claim(id);
        assertEq(got, expect);
        // auto-compounded into the lock, not paid out (G10)
        assertEq(uint256(uint128(ve.locked(id).amount)), lockedBefore + got);
    }

    // ── AERO token behavior our low-level plumbing assumes ──────────────────

    function test_fork_aeroIsWellBehavedERC20() public {
        if (skipAll) return vm.skip(true);
        address a = makeAddr("erc20a");
        address b = makeAddr("erc20b");
        vm.prank(address(ve));
        aero.transfer(a, 10e18);
        vm.prank(a);
        bool ok = aero.transfer(b, 4e18);
        assertTrue(ok, "transfer returns true");
        assertEq(aero.balanceOf(b), 4e18, "no fee on transfer");
    }
}

interface IVoterEnum {
    function pools(uint256 i) external view returns (address);
    function length() external view returns (uint256);
}
