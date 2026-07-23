// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal surface of the live Aerodrome v2 Voter on Base, hand-written
///         from the deployed code (aerodrome-finance/contracts `Voter.sol`).
/// @dev Every member below is asserted against the live deployment in
///      `test/fork/AerodromeFacts.t.sol` — the fork suite is the source of
///      truth for these signatures, not this comment.
interface IVoter {
    /// @notice The VotingEscrow this Voter governs.
    function ve() external view returns (address);

    /// @notice The Minter driving weekly emissions (used to detect a halted protocol).
    function minter() external view returns (address);

    /// @notice Casts `tokenId`'s full voting weight across `poolVote` in
    ///         proportion to `weights` (relative; the Voter normalizes).
    /// @dev Gated on-chain: once per epoch per tokenId (`onlyNewEpoch`), not in
    ///      the first hour after the flip, whitelist-only in the last hour.
    function vote(uint256 tokenId, address[] calldata poolVote, uint256[] calldata poolWeights) external;

    /// @notice Clears `tokenId`'s votes; required before escrow withdrawal.
    function reset(uint256 tokenId) external;

    /// @notice Claims bribe rewards for `tokenId`; caller must be approved-or-owner.
    ///         Rewards are transferred to the tokenId's owner.
    function claimBribes(address[] calldata bribes, address[][] calldata tokens, uint256 tokenId) external;

    /// @notice Claims fee rewards for `tokenId`; same authorization as claimBribes.
    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) external;

    // ── Public allocation state (the mirror signal, G9) ─────────────────────
    function weights(address pool) external view returns (uint256);
    function votes(uint256 tokenId, address pool) external view returns (uint256);
    function totalWeight() external view returns (uint256);
    function usedWeights(uint256 tokenId) external view returns (uint256);
    function lastVoted(uint256 tokenId) external view returns (uint256);

    /// @notice Max number of pools a single vote may name. Governance-settable —
    ///         read live, never hardcode (live value was 60 on 2026-07-23,
    ///         not the 30 the launch docs said).
    function maxVotingNum() external view returns (uint256);

    // ── Gauge / reward-contract registry (claim-target validation) ──────────
    function gauges(address pool) external view returns (address);
    function isGauge(address gauge) external view returns (bool);
    function isAlive(address gauge) external view returns (bool);
    function gaugeToFees(address gauge) external view returns (address);
    function gaugeToBribe(address gauge) external view returns (address);
    function poolForGauge(address gauge) external view returns (address);

    // ── Epoch arithmetic helpers (exposed by the live Voter) ────────────────
    function epochStart(uint256 timestamp) external view returns (uint256);
    function epochNext(uint256 timestamp) external view returns (uint256);
    function epochVoteStart(uint256 timestamp) external view returns (uint256);
    function epochVoteEnd(uint256 timestamp) external view returns (uint256);
}
