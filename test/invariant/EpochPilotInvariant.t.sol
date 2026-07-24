// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase, Vm} from "../utils/TestBase.sol";
import {MockFixture} from "../utils/MockFixture.sol";
import {EpochPilot} from "../../src/EpochPilot.sol";
import {
    MockERC20,
    MockVotingEscrow,
    MockVoter,
    MockMinter,
    MockReward,
    MockRewardsDistributor
} from "../mocks/MockProtocol.sol";

/// @dev Randomized-handler harness for the §5.4 invariants, scaled to the
///      PoC. The handler is the fuzz target; the invariant_* functions are
///      checked after every run.
contract Handler is TestBase {
    EpochPilot public pilot;
    MockERC20 public aero;
    MockERC20 public usdc;
    MockVotingEscrow public ve;
    MockVoter public voter;
    MockMinter public minter;
    MockRewardsDistributor public dist;
    MockReward public bribe;
    address public pool;
    address public gauge;
    address public pool2;
    address public gauge2;

    address[] public actors;
    uint256 public totalUsdcCredited;
    /// @dev ghost: principal-per-share must never decrease for passive holders
    uint256 public lastRatioNum; // locked principal
    uint256 public lastRatioDen; // totalShares

    constructor(
        EpochPilot pilot_,
        MockERC20 aero_,
        MockERC20 usdc_,
        MockVotingEscrow ve_,
        MockVoter voter_,
        MockMinter minter_,
        MockRewardsDistributor dist_,
        MockReward bribe_,
        address pool_,
        address gauge_,
        address pool2_,
        address gauge2_
    ) {
        pilot = pilot_;
        aero = aero_;
        usdc = usdc_;
        ve = ve_;
        voter = voter_;
        minter = minter_;
        dist = dist_;
        bribe = bribe_;
        pool = pool_;
        gauge = gauge_;
        pool2 = pool2_;
        gauge2 = gauge2_;
        for (uint256 i; i < 5; ++i) {
            address a = makeAddr(string.concat("actor", _s(i)));
            actors.push(a);
            aero.mint(a, 100_000e18);
            vm.prank(a);
            aero.approve(address(pilot), type(uint256).max);
        }
    }

    function _s(uint256 i) internal pure returns (string memory) {
        return string(abi.encodePacked(bytes1(uint8(48 + i % 10))));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _live() internal view returns (bool) {
        return pilot.activated() && !pilot.unwound() && block.timestamp < pilot.lockEnd();
    }

    // ── fuzzed operations ────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amount) external {
        if (!_live() && pilot.activated()) return;
        amount = amount % 500e18 + 1e18;
        address a = _actor(actorSeed);
        // respect the cap (bounds cumulative deposits, not TVL) so the call
        // meaningfully exercises state
        if (pilot.totalDeposited() + amount > pilot.DEPOSIT_CAP()) return;
        vm.prank(a);
        pilot.deposit(amount);
    }

    function activateIfReady() external {
        if (pilot.activated()) return;
        if (pilot.totalShares() < pilot.ACTIVATION_MIN()) return;
        pilot.activate();
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = pilot.balanceOf(from);
        if (bal == 0 || from == to) return;
        vm.prank(from);
        pilot.transfer(to, amount % bal + 1);
    }

    function creditUsdc(uint256 amount) external {
        if (!_live()) return;
        amount = amount % 1_000e18 + 1e6;
        usdc.mint(address(bribe), amount);
        bribe.notify(address(usdc), pilot.tokenId(), amount);
        _claim(address(usdc));
        totalUsdcCredited += amount - amount * pilot.BOUNTY_BPS() / 10_000;
    }

    function creditAero(uint256 amount) external {
        if (!_live()) return;
        amount = amount % 100e18 + 1e6;
        aero.mint(address(bribe), amount);
        bribe.notify(address(aero), pilot.tokenId(), amount);
        _claim(address(aero));
    }

    function _claim(address token) internal {
        address[] memory gs = new address[](1);
        gs[0] = gauge;
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = token;
        pilot.claimRevenue(gs, none, ts);
    }

    function claimUser(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        pilot.claimUser(address(usdc), 0);
    }

    function rebase(uint256 amount) external {
        if (!_live()) return;
        minter.updatePeriod(); // keepers keep the period fresh on the live protocol
        amount = amount % 50e18 + 1e6;
        aero.mint(address(dist), amount);
        dist.setClaimable(pilot.tokenId(), amount);
        pilot.claimRebase();
    }

    function compound() external {
        if (!_live()) return;
        if (aero.balanceOf(address(pilot)) == 0) return;
        pilot.compound();
    }

    function warpAndRevote(uint256 hop) external {
        if (!_live()) return;
        vm.warp(block.timestamp + hop % 3 days);
        if (!_live()) return;
        uint256 flip = voter.epochNext(block.timestamp);
        if (block.timestamp < flip - pilot.REVOTE_OPEN()) return;
        if (block.timestamp > voter.epochVoteEnd(block.timestamp)) return;
        if (voter.lastVoted(pilot.tokenId()) >= voter.epochStart(block.timestamp)) return;
        if (ve.balanceOfNFT(pilot.tokenId()) == 0) return;
        address[] memory pools = new address[](2);
        pools[0] = pool;
        pools[1] = pool2;
        pilot.revote(pools, new address[](0));
    }

    function donateAero(uint256 amount) external {
        address a = actors[0];
        amount = amount % 10e18 + 1;
        vm.prank(a);
        aero.transfer(address(pilot), amount);
    }

    // ── ghost ratio snapshot, called by the invariant checker ────────────────

    function snapshotRatio() external {
        if (!pilot.activated() || pilot.unwound()) return;
        uint256 num = uint256(uint128(ve.locked(pilot.tokenId()).amount));
        uint256 den = pilot.totalShares();
        if (den == 0) return;
        // principal/share may only grow: num/den >= lastNum/lastDen
        if (lastRatioDen != 0) {
            require(num * lastRatioDen >= lastRatioNum * den, "share value decreased");
        }
        lastRatioNum = num;
        lastRatioDen = den;
    }
}

contract EpochPilotInvariantTest is MockFixture {
    Handler handler;
    MockERC20 usdc;

    function setUp() public {
        _deployMockProtocol();
        MockReward bribe = new MockReward(ve);
        MockReward fees = new MockReward(ve);
        address pool = makeAddr("ipool");
        address gauge = makeAddr("igauge");
        address pool2 = makeAddr("ipool2");
        address gauge2 = makeAddr("igauge2");
        voter.addGauge(pool, gauge, address(fees), address(bribe), 7_000e18);
        voter.addGauge(pool2, gauge2, address(new MockReward(ve)), address(new MockReward(ve)), 3_000e18);
        usdc = new MockERC20("USD Coin", "USDC");
        handler = new Handler(pilot, aero, usdc, ve, voter, minter, dist, bribe, pool, gauge, pool2, gauge2);

        // bootstrap: one seed deposit and activation so most runs exercise
        // the post-activation surface
        aero.mint(address(this), 200e18);
        aero.approve(address(pilot), 200e18);
        pilot.deposit(200e18);
        pilot.activate();
    }

    /// @dev Runner protocol getter: fuzz only the handler.
    function targetContracts() external view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(handler);
    }

    // §5.4-1: share conservation
    function invariant_sharesConservation() external view {
        uint256 sum = pilot.balanceOf(address(this)) + pilot.balanceOf(address(0xdEaD));
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += pilot.balanceOf(handler.actors(i));
        }
        assertEq(sum, pilot.totalShares(), "sum(balances) != totalShares");
    }

    // §5.4-3 (loose-AERO ledger never exceeds what is actually on hand)
    function invariant_aeroBalanceCoversLoose() external view {
        assertGe(aero.balanceOf(address(pilot)), pilot.looseAero());
    }

    // §5.4-3: accumulator no-loss for the distributed token
    function invariant_pendingCoveredByBalance() external view {
        uint256 owed;
        for (uint256 i; i < handler.actorCount(); ++i) {
            owed += pilot.pendingUser(handler.actors(i), address(usdc));
        }
        owed += pilot.pendingUser(address(this), address(usdc));
        owed += pilot.pendingUser(address(0xdEaD), address(usdc));
        assertLe(owed, usdc.balanceOf(address(pilot)), "claimable exceeds balance");
    }

    // §5.4-2/4: principal per share never decreases (passive holders only gain)
    function invariant_shareValueMonotone() external {
        handler.snapshotRatio();
    }

    // §5.4-7: the vault never holds ETH
    function invariant_noEth() external view {
        assertEq(address(pilot).balance, 0);
    }
}
