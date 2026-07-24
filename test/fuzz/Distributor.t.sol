// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {MockFixture} from "../utils/MockFixture.sol";
import {MockReward} from "../mocks/MockProtocol.sol";
import {MockERC20} from "../mocks/MockProtocol.sol";

/// @dev Property test of the event-sourced distributor: for a random
///      interleaving of share transfers and revenue credits, every user's
///      claim must equal a reference model that replicates the contract's
///      arithmetic exactly — including credit coalescing: credits between two
///      balance changes share one entry whose perShare values sum, and the
///      payout floor-division is applied once per entry (window), not once
///      per credit. Total payouts can never exceed total credits
///      (invariant 3, §5.4).
contract DistributorFuzzTest is MockFixture {
    MockReward bribe;
    MockERC20 usdc;
    address pool = makeAddr("pool");
    address gauge = makeAddr("gauge");
    address keeper = makeAddr("keeper");

    uint256 constant N = 4;
    address[N] actors;

    // reference model state: the currently-open coalescing window
    uint256[N] winBal; // balances in force for the open window
    uint256 winPerShare; // summed perShare of credits in the open window
    uint256[N] expected;

    function setUp() public {
        _deployMockProtocol();
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
        vm.prank(keeper);
        _claimBribeToken(gauge, address(usdc));
        credited = amount - amount * pilot.BOUNTY_BPS() / 10_000;
    }

    /// @dev Close the open reference window: pay each actor floor(bal × sum / ACC).
    function _flushWindow() internal {
        if (winPerShare == 0) return;
        uint256 acc = pilot.ACC();
        for (uint256 i; i < N; ++i) {
            expected[i] += winBal[i] * winPerShare / acc;
        }
        winPerShare = 0;
    }

    function _rng(uint256 state) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(state)));
    }

    function testFuzz_distributorExactUnderTransfers(uint256 seed) public {
        uint256 totalCredited;
        uint256 r = seed;
        uint256 acc = pilot.ACC();

        for (uint256 step; step < 24; ++step) {
            r = _rng(r);
            if (r % 3 == 0) {
                // credit revenue: same-window credits coalesce, so the model
                // records each credit's individually-floored perShare into
                // the open window using balances at the window's start
                uint256 amount = 1e6 + (r >> 8) % 1_000e18;
                if (winPerShare == 0) {
                    for (uint256 i; i < N; ++i) {
                        winBal[i] = pilot.balanceOf(actors[i]);
                    }
                }
                uint256 credited = _credit(amount);
                totalCredited += credited;
                winPerShare += credited * acc / pilot.totalShares();
            } else {
                // transfer shares: closes the window (balance checkpoint
                // bumps the sequence)
                uint256 from = (r >> 16) % N;
                uint256 to = (r >> 24) % N;
                if (from == to) continue;
                uint256 bal = pilot.balanceOf(actors[from]);
                if (bal == 0) continue;
                _flushWindow();
                uint256 amt = (r >> 32) % bal + 1;
                vm.prank(actors[from]);
                pilot.transfer(actors[to], amt);
            }
        }
        _flushWindow();

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
        // one-shot expectation from the view (shared _accrue body)
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
