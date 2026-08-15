// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TestBase} from "./TestBase.sol";
import {EpochPilot} from "../../src/EpochPilot.sol";
import {
    MockERC20,
    MockVotingEscrow,
    MockVoter,
    MockMinter,
    MockReward,
    MockRewardsDistributor
} from "../mocks/MockProtocol.sol";

/// @dev Shared mock-protocol fixture: one wiring implementation for the unit,
///      fuzz and invariant suites, so a change to the link graph (which the
///      EpochPilot constructor self-checks) is made in exactly one place.
abstract contract MockFixture is TestBase {
    /// @dev Week-aligned anchor: epoch arithmetic in tests is predictable
    ///      relative to this. Derived, not magic: floor to a week boundary.
    uint256 internal constant ANCHOR = (1_784_819_744 / 7 days) * 7 days + 2 days;

    MockERC20 internal aero;
    MockVotingEscrow internal ve;
    MockVoter internal voter;
    MockMinter internal minter;
    MockRewardsDistributor internal dist;
    EpochPilot internal pilot;

    /// @dev Deploys and wires the full mock protocol plus a fresh pilot.
    function _deployMockProtocol() internal {
        vm.warp(ANCHOR);
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
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        aero.approve(address(pilot), amount);
        pilot.deposit(amount);
        vm.stopPrank();
    }

    /// @dev revote with no dead-pool exclusions (the common case in tests).
    function _revote(address[] memory pools) internal {
        pilot.revote(pools, new address[](0));
    }

    /// @dev Claims one token from one gauge's bribe contract via the vault.
    function _claimBribeToken(address gauge, address token) internal {
        address[] memory gs = new address[](1);
        gs[0] = gauge;
        address[][] memory none = new address[][](1);
        none[0] = new address[](0);
        address[][] memory ts = new address[][](1);
        ts[0] = new address[](1);
        ts[0][0] = token;
        pilot.claimRevenue(gs, none, ts);
    }
}
