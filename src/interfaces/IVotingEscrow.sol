// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal surface of the live Aerodrome v2 VotingEscrow on Base,
///         hand-written from the deployed code (`VotingEscrow.sol`).
/// @dev Asserted against the live deployment in the fork suite.
interface IVotingEscrow {
    /// @dev Matches the deployed struct layout exactly (int128 amount packed
    ///      with week-aligned unlock time and the permanent flag).
    struct LockedBalance {
        int128 amount;
        uint256 end;
        bool isPermanent;
    }

    /// @notice The locked token (AERO).
    function token() external view returns (address);

    /// @notice The RewardsDistributor wired to this escrow.
    function distributor() external view returns (address);

    /// @notice Locks `value` AERO for `lockDuration` seconds (end rounds down
    ///         to a week boundary); mints the veNFT to msg.sender.
    function createLock(uint256 value, uint256 lockDuration) external returns (uint256);

    /// @notice Adds `value` AERO to an unexpired lock; caller must be
    ///         approved-or-owner and have approved the escrow.
    function increaseAmount(uint256 tokenId, uint256 value) external;

    /// @notice Burns an expired, vote-cleared lock and returns the AERO.
    function withdraw(uint256 tokenId) external;

    function locked(uint256 tokenId) external view returns (LockedBalance memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool);
}
