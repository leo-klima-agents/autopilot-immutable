// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Minimal surface of the live Aerodrome v2 RewardsDistributor on Base.
/// @dev Rebase claims are permissionless per tokenId (G10): for an unexpired
///      lock the claim is auto-compounded into the lock via depositFor; for an
///      expired lock the AERO is transferred to the tokenId's owner. Both
///      behaviors are asserted in the fork suite.
interface IRewardsDistributor {
    function ve() external view returns (address);
    function claim(uint256 tokenId) external returns (uint256);
    function claimable(uint256 tokenId) external view returns (uint256);
}
