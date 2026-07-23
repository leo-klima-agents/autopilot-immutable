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
    MockRewardsDistributor
} from "../mocks/MockProtocol.sol";

/// @dev Property test of the event-sourced distributor: for a random
///      interleaving of share transfers and revenue credits, every user's
///      claim must equal the reference model computed from balances observed
///      at each credit event — exactly, since the arithmetic is identical —
///      and total payouts can never exceed total credits (invariant 3, §5.4).
contract DistributorFuzzTest is TestBase {
    MockERC20 aero;
    MockVotingEscrow ve;
    MockVoter voter;
    MockRewardsDistributor dist;
    EpochPilot pilot;
    MockReward bribe;
    MockERC20 usdc;
    address pool = makeAddr("pool");
    address gauge = makeAddr("gauge");
    address keeper = makeAddr("keeper");

    uint256 constant ACC = 1e27;
    uint256 constant N = 4;
    address[N] actors;

    function setUp() public {
        vm.warp(1_784_764_800 + 2 days);
        aero = new MockERC20("Aerodrome", "AERO");
        ve = new MockVotingEscrow(aero);
        voter = new MockVoter(ve);
        MockMinter minter = new MockMinter();
        minter.updatePeriod();
        voter.setMinter(address(minter));
        dist = new MockRewardsDistributor(ve, aero, minter);
        ve.setVoter(address(voter));
        ve.setDistributor(address(dist));
        pilot = new EpochPilot(address(voter));
        bribe = new MockReward(ve);
        voter.addGauge(pool, gauge, address(new MockReward(ve)), address(bribe), 1_000e18);
        usdc = new MockERC20("USD Coin", "USDC");

        actors[0] = makeAddr("a0");
        actors[1] = makeAddr("a1");
        actors[2] = makeAddr("a2");
        actors[3] = makeAddr("a3");
        for (uint256 i; i < N; ++i) {
            aero.mint(actors[i], 1_000e18);
            vm.startPrank(actors[i]);
            aero.approve(address(pilot), type(uint256).max);
            pilot.deposit(100e18 + i * 50e18);
            vm.stopPrank();
        }
        pilot.activate();
    }

    function _credit(uint256 amount) internal returns (uint256 credited) {
        usdc.mint(address(bribe), amount);
        bribe.notify(address(usdc), pilot.tokenId(), amount);
        address[] memory gs = new address[](1);
        gs[0] = gauge;
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = address(usdc);
        vm.prank(keeper);
        pilot.claimRevenue(gs, none, ts);
        credited = amount - amount * pilot.BOUNTY_BPS() / 10_000;
    }

    /// @dev PRNG step.
    function _rng(uint256 state) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(state)));
    }

    function testFuzz_distributorExactUnderTransfers(uint256 seed) public {
        uint256[N] memory expected;
        uint256 totalCredited;
        uint256 r = seed;

        for (uint256 step; step < 24; ++step) {
            r = _rng(r);
            if (r % 3 == 0) {
                // credit revenue: replicate the contract's exact math against
                // balances read at the moment of the event
                uint256 amount = 1e6 + (r >> 8) % 1_000e18;
                uint256 credited = _credit(amount);
                totalCredited += credited;
                uint256 perShare = credited * ACC / pilot.totalShares();
                for (uint256 i; i < N; ++i) {
                    expected[i] += pilot.balanceOf(actors[i]) * perShare / ACC;
                }
            } else {
                // transfer shares between random actors
                uint256 from = (r >> 16) % N;
                uint256 to = (r >> 24) % N;
                if (from == to) continue;
                uint256 bal = pilot.balanceOf(actors[from]);
                if (bal == 0) continue;
                uint256 amt = (r >> 32) % bal + 1;
                vm.prank(actors[from]);
                pilot.transfer(actors[to], amt);
            }
        }

        uint256 totalPaid;
        for (uint256 i; i < N; ++i) {
            vm.prank(actors[i]);
            uint256 got = pilot.claimUser(address(usdc), 0);
            assertEq(got, expected[i], "claim != reference model");
            totalPaid += got;
        }
        // no-loss: users can never pull more than was credited (dust from
        // floor division and the dead shares' unclaimed slice stay behind)
        assertLe(totalPaid, totalCredited, "paid > credited");
        assertLe(totalPaid, usdc.balanceOf(address(pilot)) + totalPaid, "balance underflow");
        // second claim pays nothing
        vm.prank(actors[0]);
        assertEq(pilot.claimUser(address(usdc), 0), 0);
    }

    function testFuzz_batchedClaimEqualsOneShot(uint256 seed, uint8 batch) public {
        uint256 r = seed;
        for (uint256 i; i < 6; ++i) {
            r = _rng(r);
            _credit(1e6 + r % 100e18);
            uint256 bal = pilot.balanceOf(actors[0]);
            uint256 amt = (r >> 64) % bal + 1;
            vm.prank(actors[0]);
            pilot.transfer(actors[1], amt);
        }
        // one-shot expectation from the view
        uint256 want = pilot.pendingUser(actors[1], address(usdc));
        uint256 got;
        uint256 step = uint256(batch) % 3 + 1;
        for (uint256 guard; guard < 10; ++guard) {
            vm.prank(actors[1]);
            got += pilot.claimUser(address(usdc), step);
            if (pilot.claimCursor(actors[1], address(usdc)) == pilot.creditCount(address(usdc))) break;
        }
        assertEq(got, want, "batched != one-shot");
    }
}
