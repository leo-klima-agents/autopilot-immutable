// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Minimal ERC-20 surface used by EpochPilot.
/// @dev Hand-written per the no-external-dependencies rule (§5.1). Reward
///      tokens are NOT trusted to honor this interface — every transfer of a
///      reward token goes through the low-level `_push` path in the vault,
///      which tolerates missing return values (weird-erc20).
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}
