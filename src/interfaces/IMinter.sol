// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal surface of the live Aerodrome v2 Minter on Base.
/// @dev Only `activePeriod` is used: the RewardsDistributor refuses claims
///      while the minter's period is stale (`activePeriod < week-floor(now)`),
///      so the vault mirrors that exact precondition to *skip* the final
///      rebase claim during unwind instead of letting a halted protocol
///      brick principal withdrawal. Asserted in the fork suite.
interface IMinter {
    function activePeriod() external view returns (uint256);
}
