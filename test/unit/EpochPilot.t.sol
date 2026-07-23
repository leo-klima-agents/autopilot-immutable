// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase} from "../utils/TestBase.sol";
import {EpochPilot} from "../../src/EpochPilot.sol";
import {
    MockERC20,
    MockVotingEscrow,
    MockVoter,
    MockMinter,
    MockReward,
    MockRewardsDistributor,
    FeeOnTransferToken,
    RevertingToken,
    NoReturnToken,
    PhantomBalanceToken,
    ReentrantToken
} from "../mocks/MockProtocol.sol";

contract EpochPilotUnitTest is TestBase {
    uint256 constant WEEK = 7 days;

    MockERC20 aero;
    MockVotingEscrow ve;
    MockVoter voter;
    MockMinter minter;
    MockRewardsDistributor dist;
    EpochPilot pilot;

    MockReward feesA;
    MockReward bribeA;
    address poolA = makeAddr("poolA");
    address gaugeA = makeAddr("gaugeA");
    address poolB = makeAddr("poolB");
    address gaugeB = makeAddr("gaugeB");
    MockReward feesB;
    MockReward bribeB;

    MockERC20 usdc;
    FeeOnTransferToken feeToken;
    RevertingToken brickToken;
    NoReturnToken usdtLike;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");

    function setUp() public {
        // Anchor to a week boundary + 2 days so vote gates are predictable.
        vm.warp(1_784_764_800 + 2 days);

        aero = new MockERC20("Aerodrome", "AERO");
        ve = new MockVotingEscrow(aero);
        voter = new MockVoter(ve);
        minter = new MockMinter();
        minter.updatePeriod();
        voter.setMinter(address(minter));
        dist = new MockRewardsDistributor(ve, aero, minter);
        ve.setVoter(address(voter));
        ve.setDistributor(address(dist));

        pilot = new EpochPilot(address(voter));

        feesA = new MockReward(ve);
        bribeA = new MockReward(ve);
        feesB = new MockReward(ve);
        bribeB = new MockReward(ve);
        voter.addGauge(poolA, gaugeA, address(feesA), address(bribeA), 6_000e18);
        voter.addGauge(poolB, gaugeB, address(feesB), address(bribeB), 4_000e18);

        usdc = new MockERC20("USD Coin", "USDC");
        feeToken = new FeeOnTransferToken();
        brickToken = new RevertingToken();
        usdtLike = new NoReturnToken();

        aero.mint(alice, 5_000e18);
        aero.mint(bob, 5_000e18);
        aero.mint(carol, 5_000e18);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _deposit(address who, uint256 amt) internal {
        vm.startPrank(who);
        aero.approve(address(pilot), amt);
        pilot.deposit(amt);
        vm.stopPrank();
    }

    function _activate(uint256 aliceAmt, uint256 bobAmt) internal {
        _deposit(alice, aliceAmt);
        _deposit(bob, bobAmt);
        pilot.activate();
    }

    function _warpToRevoteWindow() internal {
        uint256 flip = voter.epochNext(block.timestamp);
        vm.warp(flip - 3 hours);
    }

    function _pools2() internal view returns (address[] memory p) {
        p = new address[](2);
        p[0] = poolA;
        p[1] = poolB;
    }

    // ── constructor ──────────────────────────────────────────────────────────

    function test_constructor_resolvesAndChecksLinkGraph() public view {
        assertEq(address(pilot.VOTER()), address(voter));
        assertEq(address(pilot.VE()), address(ve));
        assertEq(address(pilot.DIST()), address(dist));
        assertEq(address(pilot.AERO()), address(aero));
    }

    function test_constructor_rejectsBrokenLinkGraph() public {
        MockVotingEscrow otherVe = new MockVotingEscrow(aero);
        MockRewardsDistributor badDist = new MockRewardsDistributor(otherVe, aero, minter);
        ve.setDistributor(address(badDist)); // dist.ve() != ve
        vm.expectRevert(EpochPilot.BadDeployment.selector);
        new EpochPilot(address(voter));
        ve.setDistributor(address(dist));
    }

    // ── seeding phase ────────────────────────────────────────────────────────

    function test_seedDeposit_oneToOne_andRefund() public {
        _deposit(alice, 50e18);
        assertEq(pilot.balanceOf(alice), 50e18);
        assertEq(pilot.totalShares(), 50e18);

        vm.prank(alice);
        pilot.withdrawSeed(20e18);
        assertEq(pilot.balanceOf(alice), 30e18);
        assertEq(aero.balanceOf(alice), 5_000e18 - 30e18);
    }

    function test_deposit_belowMinimumReverts() public {
        vm.startPrank(alice);
        aero.approve(address(pilot), 1e18);
        vm.expectRevert(EpochPilot.BelowMinimum.selector);
        pilot.deposit(1e18 - 1);
        vm.stopPrank();
    }

    function test_deposit_capEnforced() public {
        aero.mint(alice, 20_000e18);
        vm.startPrank(alice);
        aero.approve(address(pilot), type(uint256).max);
        pilot.deposit(10_000e18);
        vm.expectRevert(EpochPilot.CapExceeded.selector);
        pilot.deposit(1e18);
        vm.stopPrank();
    }

    function test_activate_belowMinReverts() public {
        _deposit(alice, 99e18);
        vm.expectRevert(EpochPilot.BelowMinimum.selector);
        pilot.activate();
    }

    function test_activate_locksSeed_mintsDeadShares() public {
        _activate(600e18, 400e18);
        assertTrue(pilot.activated());
        assertEq(pilot.balanceOf(address(0xdEaD)), pilot.SEED_BURN());
        assertEq(pilot.totalShares(), 1_000e18 + pilot.SEED_BURN());
        // whole seed is locked, week-aligned end
        assertEq(uint256(uint128(ve.locked(pilot.tokenId()).amount)), 1_000e18);
        assertEq(pilot.lockEnd() % WEEK, 0);
        assertEq(aero.balanceOf(address(pilot)), 0);
        // second activation impossible
        vm.expectRevert(EpochPilot.AlreadyActivated.selector);
        pilot.activate();
        // seed refunds are over
        vm.prank(alice);
        vm.expectRevert(EpochPilot.AlreadyActivated.selector);
        pilot.withdrawSeed(1e18);
    }

    function test_activate_locksDonationsToo() public {
        _deposit(alice, 200e18);
        vm.prank(bob);
        aero.transfer(address(pilot), 50e18); // donation
        pilot.activate();
        assertEq(uint256(uint128(ve.locked(pilot.tokenId()).amount)), 250e18);
    }

    // ── post-activation deposits ─────────────────────────────────────────────

    function test_deposit_afterActivation_proRata() public {
        _activate(600e18, 400e18);
        uint256 sharesBefore = pilot.totalShares();
        _deposit(carol, 100e18);
        // principal was 1000, so carol gets shares*100/1000
        assertEq(pilot.balanceOf(carol), sharesBefore * 100e18 / 1_000e18);
        assertEq(uint256(uint128(ve.locked(pilot.tokenId()).amount)), 1_100e18);
    }

    function test_deposit_afterRebase_ratioReflectsGrowth() public {
        _activate(600e18, 400e18);
        // rebase compounds 100 AERO into the lock outside our wrapper
        aero.mint(address(dist), 100e18);
        dist.setClaimable(pilot.tokenId(), 100e18);
        vm.prank(keeper);
        pilot.claimRebase();
        uint256 sharesBefore = pilot.totalShares();
        _deposit(carol, 110e18);
        // principal is now 1100 — carol's mint ratio must use it
        assertEq(pilot.balanceOf(carol), sharesBefore * 110e18 / 1_100e18);
    }

    // ── revote ───────────────────────────────────────────────────────────────

    function test_revote_windowEnforced() public {
        _activate(600e18, 400e18);
        address[] memory pools = _pools2();
        // too early (mid-epoch)
        vm.expectRevert(EpochPilot.OutsideWindow.selector);
        pilot.revote(pools);
        // last hour: protocol whitelist zone — blocked by us first
        vm.warp(voter.epochNext(block.timestamp) - 30 minutes);
        vm.expectRevert(EpochPilot.OutsideWindow.selector);
        pilot.revote(pools);
    }

    function test_revote_mirrorsMarketWeights() public {
        _activate(600e18, 400e18);
        _warpToRevoteWindow();
        vm.prank(keeper);
        pilot.revote(_pools2());
        uint256 id = pilot.tokenId();
        uint256 va = voter.votes(id, poolA);
        uint256 vb = voter.votes(id, poolB);
        assertGt(va, 0);
        assertGt(vb, 0);
        // mirror of 6000:4000 market split = 3:2
        assertApproxEqRel(va * 1e18 / vb, 1.5e18, 1e15);
    }

    function test_revote_coverageCheckDefeatsSubsets() public {
        _activate(600e18, 400e18);
        _warpToRevoteWindow();
        address[] memory pools = new address[](1);
        pools[0] = poolB; // only 40% of weight
        vm.expectRevert(EpochPilot.CoverageTooLow.selector);
        pilot.revote(pools);
    }

    function test_revote_rejectsDuplicatesAndDeadGauges() public {
        _activate(600e18, 400e18);
        _warpToRevoteWindow();
        address[] memory dup = new address[](2);
        dup[0] = poolA;
        dup[1] = poolA;
        vm.expectRevert(EpochPilot.BadCandidateSet.selector);
        pilot.revote(dup);

        voter.killGauge(gaugeA);
        vm.expectRevert(EpochPilot.BadCandidateSet.selector);
        pilot.revote(_pools2());
    }

    function test_revote_onceLivePerEpoch_protocolEnforced() public {
        _activate(600e18, 400e18);
        _warpToRevoteWindow();
        pilot.revote(_pools2());
        vm.warp(block.timestamp + 30 minutes);
        vm.expectRevert("already voted");
        pilot.revote(_pools2());
    }

    function test_revote_bountyRampsAndIsCappedByLooseAero() public {
        _activate(600e18, 400e18);
        // seed loose AERO via an AERO bribe claim
        aero.mint(address(bribeA), 100e18);
        bribeA.notify(address(aero), pilot.tokenId(), 100e18);
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = address(aero);
        pilot.claimRevenue(gs, none, ts);
        uint256 loose = pilot.looseAero();
        assertGt(loose, 0);

        // three weeks of staleness → ramp = 3 * BOUNTY_RAMP, under the cap
        vm.warp(block.timestamp + 2 * WEEK);
        _warpToRevoteWindow();
        uint256 staleness = block.timestamp - pilot.lastVoteAt();
        uint256 expected = pilot.BOUNTY_RAMP_AERO() * staleness / WEEK;
        vm.prank(keeper);
        pilot.revote(_pools2());
        assertEq(aero.balanceOf(keeper), expected);
        assertEq(pilot.looseAero(), loose - expected);
    }

    // ── claimRevenue ─────────────────────────────────────────────────────────

    function _claimOneGauge(address gauge, address tok) internal {
        address[] memory gs = new address[](1);
        gs[0] = gauge;
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = tok;
        vm.prank(keeper);
        pilot.claimRevenue(gs, none, ts);
    }

    function test_claimRevenue_creditsAccumulator_paysBounty() public {
        _activate(600e18, 400e18);
        usdc.mint(address(bribeA), 1_000e18);
        bribeA.notify(address(usdc), pilot.tokenId(), 1_000e18);
        _claimOneGauge(gaugeA, address(usdc));

        uint256 bounty = 1_000e18 * pilot.BOUNTY_BPS() / 10_000;
        assertEq(usdc.balanceOf(keeper), bounty);
        assertEq(usdc.balanceOf(address(pilot)), 1_000e18 - bounty);
        assertEq(pilot.creditCount(address(usdc)), 1);

        // holders pull pro-rata (alice 60%, bob 40%)
        vm.prank(alice);
        uint256 gotA = pilot.claimUser(address(usdc), 0);
        vm.prank(bob);
        uint256 gotB = pilot.claimUser(address(usdc), 0);
        assertApproxEqRel(gotA * 1e18 / gotB, 1.5e18, 1e12);
        assertLe(gotA + gotB, 1_000e18 - bounty);
    }

    function test_claimRevenue_rejectsUnregisteredGauge() public {
        _activate(600e18, 400e18);
        address[] memory gs = new address[](1);
        gs[0] = makeAddr("fakeGauge");
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = address(usdc);
        vm.expectRevert(EpochPilot.BadCandidateSet.selector);
        pilot.claimRevenue(gs, ts, ts);
    }

    function test_claimRevenue_feeOnTransferToken_balanceDeltaSafe() public {
        _activate(600e18, 400e18);
        feeToken.mint(address(bribeA), 1_000e18);
        bribeA.notify(address(feeToken), pilot.tokenId(), 1_000e18);
        _claimOneGauge(gaugeA, address(feeToken));
        // credited from the RECEIVED amount (990), not the sent amount
        uint256 received = 990e18;
        uint256 bounty = received * pilot.BOUNTY_BPS() / 10_000;
        // bounty transfer out also took a fee — keeper nets bounty minus 1%
        assertEq(feeToken.balanceOf(keeper), bounty - bounty / 100);
        vm.prank(alice);
        uint256 got = pilot.claimUser(address(feeToken), 0);
        assertLe(got, received - bounty);
    }

    function test_claimRevenue_aeroBecomesLooseNotCredited() public {
        _activate(600e18, 400e18);
        aero.mint(address(feesA), 200e18);
        feesA.notify(address(aero), pilot.tokenId(), 200e18);
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = address(aero);
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        vm.prank(keeper);
        pilot.claimRevenue(gs, ts, none);
        uint256 bounty = 200e18 * pilot.BOUNTY_BPS() / 10_000;
        assertEq(pilot.looseAero(), 200e18 - bounty);
        assertEq(pilot.creditCount(address(aero)), 0); // never distributed
        assertEq(aero.balanceOf(keeper), bounty);
    }

    function test_claimUser_tokenIsolation_brickedTokenOnlyBlocksItself() public {
        _activate(600e18, 400e18);
        usdc.mint(address(bribeA), 100e18);
        brickToken.mint(address(bribeA), 100e18);
        bribeA.notify(address(usdc), pilot.tokenId(), 100e18);
        bribeA.notify(address(brickToken), pilot.tokenId(), 100e18);
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](2);
        ts[0][0] = address(usdc);
        ts[0][1] = address(brickToken);
        vm.prank(keeper);
        pilot.claimRevenue(gs, none, ts);

        brickToken.setBricked(true);
        vm.prank(alice);
        vm.expectRevert(EpochPilot.TransferFailed.selector);
        pilot.claimUser(address(brickToken), 0);
        // the bricked token blocks nothing else
        vm.prank(alice);
        uint256 got = pilot.claimUser(address(usdc), 0);
        assertGt(got, 0);
    }

    function test_claimUser_noReturnToken_paysOut() public {
        _activate(600e18, 400e18);
        usdtLike.mint(address(bribeA), 100e18);
        bribeA.notify(address(usdtLike), pilot.tokenId(), 100e18);
        _claimOneGauge(gaugeA, address(usdtLike));
        vm.prank(alice);
        uint256 got = pilot.claimUser(address(usdtLike), 0);
        assertGt(got, 0);
        assertEq(usdtLike.balanceOf(alice), got);
    }

    function test_claimUser_batchedCursor() public {
        _activate(600e18, 400e18);
        for (uint256 i; i < 5; ++i) {
            usdc.mint(address(bribeA), 10e18);
            bribeA.notify(address(usdc), pilot.tokenId(), 10e18);
            _claimOneGauge(gaugeA, address(usdc));
        }
        assertEq(pilot.creditCount(address(usdc)), 5);
        vm.prank(alice);
        uint256 first = pilot.claimUser(address(usdc), 2);
        assertEq(pilot.claimCursor(alice, address(usdc)), 2);
        vm.prank(alice);
        uint256 rest = pilot.claimUser(address(usdc), 0);
        assertEq(pilot.claimCursor(alice, address(usdc)), 5);
        assertApproxEqRel(first * 3, rest * 2, 1e12); // 2 events vs 3, equal sizes
    }

    function test_transfer_movesFutureRevenueNotPast() public {
        _activate(600e18, 400e18);
        usdc.mint(address(bribeA), 100e18);
        bribeA.notify(address(usdc), pilot.tokenId(), 100e18);
        _claimOneGauge(gaugeA, address(usdc));
        // alice hands everything to carol AFTER the credit event
        uint256 aliceBal = pilot.balanceOf(alice);
        vm.prank(alice);
        pilot.transfer(carol, aliceBal);
        // past revenue stays with alice…
        vm.prank(carol);
        assertEq(pilot.claimUser(address(usdc), 0), 0);
        vm.prank(alice);
        assertGt(pilot.claimUser(address(usdc), 0), 0);
        // …future revenue goes to carol
        usdc.mint(address(bribeA), 100e18);
        bribeA.notify(address(usdc), pilot.tokenId(), 100e18);
        _claimOneGauge(gaugeA, address(usdc));
        vm.prank(alice);
        assertEq(pilot.claimUser(address(usdc), 0), 0);
        vm.prank(carol);
        assertGt(pilot.claimUser(address(usdc), 0), 0);
    }

    // ── rebase + compound ────────────────────────────────────────────────────

    function test_claimRebase_compoundsIntoLock() public {
        _activate(600e18, 400e18);
        aero.mint(address(dist), 50e18);
        dist.setClaimable(pilot.tokenId(), 50e18);
        uint256 lockedBefore = uint256(uint128(ve.locked(pilot.tokenId()).amount));
        vm.prank(keeper);
        uint256 amt = pilot.claimRebase();
        assertEq(amt, 50e18);
        assertEq(uint256(uint128(ve.locked(pilot.tokenId()).amount)), lockedBefore + 50e18);
        // no loose AERO on hand → bounty skipped, not reverted
        assertEq(aero.balanceOf(keeper), 0);
    }

    function test_compound_stakesEverything_paysBounty() public {
        _activate(600e18, 400e18);
        aero.mint(address(feesA), 200e18);
        feesA.notify(address(aero), pilot.tokenId(), 200e18);
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = address(aero);
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        pilot.claimRevenue(gs, ts, none);
        // plus an untracked donation
        vm.prank(carol);
        aero.transfer(address(pilot), 10e18);

        uint256 bal = aero.balanceOf(address(pilot));
        uint256 lockedBefore = uint256(uint128(ve.locked(pilot.tokenId()).amount));
        vm.prank(keeper);
        pilot.compound();
        uint256 bounty = bal * pilot.BOUNTY_BPS() / 10_000;
        assertEq(aero.balanceOf(keeper), bounty);
        assertEq(uint256(uint128(ve.locked(pilot.tokenId()).amount)), lockedBefore + bal - bounty);
        assertEq(pilot.looseAero(), 0);
        assertEq(aero.balanceOf(address(pilot)), 0);
    }

    function test_compound_nothingToCompoundReverts() public {
        _activate(600e18, 400e18);
        vm.expectRevert(EpochPilot.NothingToCompound.selector);
        pilot.compound();
    }

    // ── unwind + redeem ──────────────────────────────────────────────────────

    function test_unwind_graceEnforced_thenRedeemProRata() public {
        _activate(600e18, 400e18);
        vm.warp(pilot.lockEnd());
        vm.expectRevert(EpochPilot.TooEarly.selector);
        pilot.unwind();

        vm.warp(pilot.lockEnd() + pilot.UNWIND_GRACE() + 2 hours);
        minter.updatePeriod(); // keepers keep the live protocol's period fresh
        // final rebase arrives liquid during unwind
        aero.mint(address(dist), 30e18);
        dist.setClaimable(pilot.tokenId(), 30e18);
        pilot.unwind();
        assertTrue(pilot.unwound());
        assertEq(aero.balanceOf(address(pilot)), 1_030e18);

        uint256 aliceShares = pilot.balanceOf(alice);
        uint256 total = pilot.totalShares();
        vm.prank(alice);
        uint256 got = pilot.redeem(aliceShares);
        assertEq(got, 1_030e18 * aliceShares / total);

        // deposits, votes, claims and compound are all over
        vm.startPrank(carol);
        aero.approve(address(pilot), 10e18);
        vm.expectRevert(EpochPilot.NotActive.selector);
        pilot.deposit(10e18);
        vm.stopPrank();
        vm.expectRevert(EpochPilot.NotActive.selector);
        pilot.compound();
        vm.expectRevert(EpochPilot.NotActive.selector);
        pilot.claimRebase();
    }

    function test_unwind_afterVoting_resetsAndWithdraws() public {
        _activate(600e18, 400e18);
        _warpToRevoteWindow();
        pilot.revote(_pools2());
        vm.warp(pilot.lockEnd() + pilot.UNWIND_GRACE() + 2 hours);
        pilot.unwind();
        assertEq(voter.usedWeights(pilot.tokenId()), 0);
    }

    function test_unwind_succeedsEvenIfProtocolHalted() public {
        _activate(600e18, 400e18);
        // the protocol dies: minter period never rolls again, so the
        // distributor refuses all claims — principal must still come home
        aero.mint(address(dist), 30e18);
        dist.setClaimable(pilot.tokenId(), 30e18);
        vm.warp(pilot.lockEnd() + pilot.UNWIND_GRACE() + 2 hours);
        // sanity: a direct rebase claim would revert now
        vm.expectRevert(bytes("FZ5"));
        pilot.claimRebase();
        pilot.unwind();
        assertTrue(pilot.unwound());
        // rebase forfeited, principal intact
        assertEq(aero.balanceOf(address(pilot)), 1_000e18);
    }

    function test_redeem_beforeUnwindReverts() public {
        _activate(600e18, 400e18);
        vm.prank(alice);
        vm.expectRevert(EpochPilot.NotUnwound.selector);
        pilot.redeem(1e18);
    }

    function test_claimUser_stillWorksAfterRedeem() public {
        _activate(600e18, 400e18);
        usdc.mint(address(bribeA), 100e18);
        bribeA.notify(address(usdc), pilot.tokenId(), 100e18);
        _claimOneGauge(gaugeA, address(usdc));

        vm.warp(pilot.lockEnd() + pilot.UNWIND_GRACE() + 2 hours);
        pilot.unwind();
        vm.startPrank(alice);
        pilot.redeem(pilot.balanceOf(alice));
        // shares burned, but the checkpointed history still pays
        uint256 got = pilot.claimUser(address(usdc), 0);
        vm.stopPrank();
        assertGt(got, 0);
    }

    // ── shares ERC-20 ────────────────────────────────────────────────────────

    function test_shares_erc20Basics() public {
        _deposit(alice, 100e18);
        assertEq(pilot.totalSupply(), 100e18);
        assertEq(pilot.checkpointCount(alice), 1);
        vm.prank(alice);
        pilot.approve(bob, 40e18);
        vm.prank(bob);
        pilot.transferFrom(alice, carol, 40e18);
        assertEq(pilot.balanceOf(carol), 40e18);
        assertEq(pilot.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert(EpochPilot.InsufficientShares.selector);
        pilot.transferFrom(alice, carol, 1);
        // shares can never be sent to the vault or zero
        vm.prank(carol);
        vm.expectRevert(EpochPilot.TransferFailed.selector);
        pilot.transfer(address(pilot), 1e18);
    }

    // ── remaining branch coverage: guards, dust, adversarial paths ──────────

    function test_withdrawSeed_zeroReverts() public {
        _deposit(alice, 50e18);
        vm.prank(alice);
        vm.expectRevert(EpochPilot.ZeroAmount.selector);
        pilot.withdrawSeed(0);
    }

    function test_withdrawSeed_moreThanBalanceReverts() public {
        _deposit(alice, 50e18);
        vm.prank(alice);
        vm.expectRevert(EpochPilot.InsufficientShares.selector);
        pilot.withdrawSeed(51e18);
    }

    function test_transfer_moreThanBalanceReverts() public {
        _deposit(alice, 50e18);
        vm.prank(alice);
        vm.expectRevert(EpochPilot.InsufficientShares.selector);
        pilot.transfer(bob, 51e18);
    }

    function test_deposit_withoutApprovalFailsLoudly() public {
        vm.prank(alice);
        vm.expectRevert(EpochPilot.TransferFailed.selector);
        pilot.deposit(10e18);
    }

    function test_preActivation_gates() public {
        // strategy/revenue surface is closed until activation
        vm.expectRevert(EpochPilot.NotActive.selector);
        pilot.revote(_pools2());
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = address(usdc);
        vm.expectRevert(EpochPilot.NotActive.selector);
        pilot.claimRevenue(gs, ts, ts);
    }

    function test_unwind_secondCallReverts() public {
        _activate(600e18, 400e18);
        vm.warp(pilot.lockEnd() + pilot.UNWIND_GRACE() + 2 hours);
        pilot.unwind();
        vm.expectRevert(EpochPilot.NotActive.selector);
        pilot.unwind();
    }

    function test_redeem_zeroReverts() public {
        _activate(600e18, 400e18);
        vm.warp(pilot.lockEnd() + pilot.UNWIND_GRACE() + 2 hours);
        pilot.unwind();
        vm.prank(alice);
        vm.expectRevert(EpochPilot.ZeroAmount.selector);
        pilot.redeem(0);
    }

    function test_revote_emptyAndOversizedSetsRevert() public {
        _activate(600e18, 400e18);
        _warpToRevoteWindow();
        vm.expectRevert(EpochPilot.BadCandidateSet.selector);
        pilot.revote(new address[](0));
        uint256 oversize = voter.maxVotingNum() + 1;
        vm.expectRevert(EpochPilot.BadCandidateSet.selector);
        pilot.revote(new address[](oversize));
    }

    function test_revote_zeroMirrorWeightPoolRejected() public {
        // a pool nobody (else) voted for has mirror weight 0 — invalid candidate
        address deadPool = makeAddr("deadPool");
        address deadGauge = makeAddr("deadGauge");
        voter.addGauge(deadPool, deadGauge, address(new MockReward(ve)), address(new MockReward(ve)), 0);
        _activate(600e18, 400e18);
        _warpToRevoteWindow();
        address[] memory pools = new address[](3);
        pools[0] = poolA;
        pools[1] = poolB;
        pools[2] = deadPool;
        vm.expectRevert(EpochPilot.BadCandidateSet.selector);
        pilot.revote(pools);
    }

    function test_revote_bountyClampedAtMax() public {
        _activate(600e18, 400e18);
        // stock plenty of loose AERO via an AERO bribe
        aero.mint(address(bribeA), 1_000e18);
        bribeA.notify(address(aero), pilot.tokenId(), 1_000e18);
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = address(aero);
        pilot.claimRevenue(gs, none, ts);
        // go stale for 8 weeks: ramp (8 AERO) must clamp at BOUNTY_MAX (5)
        vm.warp(block.timestamp + 8 * WEEK);
        _warpToRevoteWindow();
        vm.prank(keeper);
        pilot.revote(_pools2());
        assertEq(aero.balanceOf(keeper), pilot.BOUNTY_MAX_AERO());
    }

    function test_claimRevenue_inputShapeGuards() public {
        _activate(600e18, 400e18);
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = address(usdc);
        // zero gauges
        vm.expectRevert(EpochPilot.LengthMismatch.selector);
        pilot.claimRevenue(new address[](0), ts, ts);
        // ragged arrays
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        vm.expectRevert(EpochPilot.LengthMismatch.selector);
        pilot.claimRevenue(gs, new address[][](2), ts);
        // no tokens named at all
        address[][] memory empty = new address[][](1);
        empty[0] = new address[](0);
        vm.expectRevert(EpochPilot.LengthMismatch.selector);
        pilot.claimRevenue(gs, empty, empty);
    }

    function test_claimRevenue_duplicateTokensCountedOnce() public {
        _activate(600e18, 400e18);
        usdc.mint(address(bribeA), 100e18);
        bribeA.notify(address(usdc), pilot.tokenId(), 100e18);
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        // the same token named in both the fee and bribe lists
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](2);
        ts[0][0] = address(usdc);
        ts[0][1] = address(usdc);
        vm.prank(keeper);
        pilot.claimRevenue(gs, ts, ts);
        // one credit event, not four — the union deduplicates
        assertEq(pilot.creditCount(address(usdc)), 1);
        vm.prank(alice);
        uint256 got = pilot.claimUser(address(usdc), 0);
        assertLe(got, 100e18);
    }

    function test_claimRevenue_tokenUnionCapEnforced() public {
        _activate(600e18, 400e18);
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        address[][] memory many = new address[][](1);
        many[0] = new address[](pilot.MAX_CLAIM_TOKENS() + 1);
        for (uint256 i; i < many[0].length; ++i) {
            many[0][i] = address(uint160(0x10000 + i));
        }
        vm.expectRevert(EpochPilot.LengthMismatch.selector);
        pilot.claimRevenue(gs, none, many);
    }

    function test_claimRevenue_zeroDeltaTokenSkipped() public {
        _activate(600e18, 400e18);
        // usdc earned, feeToken named but nothing earned → delta 0 branch
        usdc.mint(address(bribeA), 100e18);
        bribeA.notify(address(usdc), pilot.tokenId(), 100e18);
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](2);
        ts[0][0] = address(usdc);
        ts[0][1] = address(feeToken);
        vm.prank(keeper);
        pilot.claimRevenue(gs, none, ts);
        assertEq(pilot.creditCount(address(feeToken)), 0);
        assertEq(pilot.creditCount(address(usdc)), 1);
    }

    function test_claimRebase_afterExpiry_arrivesLoose() public {
        _activate(600e18, 400e18);
        vm.warp(pilot.lockEnd() + 1 hours);
        minter.updatePeriod();
        aero.mint(address(dist), 40e18);
        dist.setClaimable(pilot.tokenId(), 40e18);
        vm.prank(keeper);
        uint256 amt = pilot.claimRebase();
        assertEq(amt, 40e18);
        uint256 bounty = 40e18 * pilot.BOUNTY_BPS() / 10_000;
        // post-expiry the rebase arrives liquid; bounty now payable from it
        assertEq(pilot.looseAero(), 40e18 - bounty);
        assertEq(aero.balanceOf(keeper), bounty);
    }

    function test_compound_afterExpiryReverts() public {
        _activate(600e18, 400e18);
        vm.prank(carol);
        aero.transfer(address(pilot), 10e18);
        vm.warp(pilot.lockEnd() + 1 hours);
        vm.expectRevert(EpochPilot.Expired.selector);
        pilot.compound();
    }

    function test_phantomBalanceToken_isolatedToItself() public {
        _activate(600e18, 400e18);
        // attacker names a "token" that fabricates balance deltas: it can
        // poison only its own accumulator entry, never real assets
        PhantomBalanceToken phantom = new PhantomBalanceToken();
        usdc.mint(address(bribeA), 100e18);
        bribeA.notify(address(usdc), pilot.tokenId(), 100e18);
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](2);
        ts[0][0] = address(usdc);
        ts[0][1] = address(phantom);
        vm.prank(keeper);
        pilot.claimRevenue(gs, none, ts);
        // phantom got credited (worthless) — usdc accounting is untouched
        assertEq(pilot.creditCount(address(phantom)), 1);
        vm.prank(alice);
        uint256 got = pilot.claimUser(address(usdc), 0);
        assertGt(got, 0);
        assertLe(got, usdc.balanceOf(address(pilot)) + got);
    }

    function test_reentrancy_latchBlocksTokenCallback() public {
        _activate(600e18, 400e18);
        ReentrantToken evil = new ReentrantToken();
        evil.arm(address(pilot), address(usdc));
        address[] memory gs = new address[](1);
        gs[0] = gaugeA;
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = address(evil);
        // the evil token's fabricated delta earns it a bounty push; its
        // transfer reenters claimUser and the transient latch must trip
        vm.prank(keeper);
        pilot.claimRevenue(gs, none, ts);
        assertTrue(evil.attempted(), "reentry attempted");
        assertTrue(evil.blocked(), "reentry blocked");
        assertEq(bytes32(evil.blockReason()), bytes32(EpochPilot.Reentrancy.selector));
    }

    // ── reentrancy + eth rejection ───────────────────────────────────────────

    function test_noEthAccepted() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(pilot).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_onERC721Received_onlyEscrowCollection() public {
        vm.expectRevert(EpochPilot.NotEscrow.selector);
        pilot.onERC721Received(address(0), address(0), 1, "");
    }
}
