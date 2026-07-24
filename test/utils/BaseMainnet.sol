// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Single source of truth for the fork suites' chain fixture: the AERO
///      root-of-trust address (identity asserted on-chain by every consumer)
///      and the pinned block at which all protocol facts were asserted.
///      One definition, so the facts suite and the lifecycle suite can never
///      silently run against different chain states.
library BaseMainnet {
    address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    /// @dev Override at runtime with BASE_FORK_BLOCK.
    uint256 internal constant FORK_BLOCK = 49_016_010;
}
