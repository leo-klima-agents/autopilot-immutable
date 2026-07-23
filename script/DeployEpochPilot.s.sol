// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {EpochPilot} from "../src/EpochPilot.sol";
import {IVoter} from "../src/interfaces/IVoter.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../src/interfaces/IRewardsDistributor.sol";

interface ScriptVm {
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function startBroadcast() external;
    function stopBroadcast() external;
    function toString(address value) external pure returns (string memory);
}

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function minter() external view returns (address);
}

interface IMinter {
    function voter() external view returns (address);
}

/// @title  Deterministic, privilege-free deployment of EpochPilot (§8)
/// @notice CREATE2 through the canonical deterministic-deployment proxy
///         (forge routes salted creations through 0x4e59b44847b379578588920cA78FbF26c0B4956C),
///         so the address is derivable from (salt, init-code hash) alone —
///         both recorded in verification/. Zero post-deploy calls: the
///         constructor resolves and self-checks every protocol link, and the
///         deployer holds no residual power the moment it returns.
///
///         Addresses are never taken from documents: the sole root of trust
///         is the canonical AERO token (identity asserted by symbol), and the
///         Voter is resolved on-chain via AERO → minter → voter at the moment
///         of use. Override the root with AERO_TOKEN for rehearsal networks.
///
///         Run: forge script script/DeployEpochPilot.s.sol --rpc-url base --broadcast
contract DeployEpochPilot {
    ScriptVm internal constant vm = ScriptVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bool public IS_SCRIPT = true;

    /// @dev Release-series salt. Bump the series name for any new deployment.
    bytes32 public constant SALT = keccak256("tranche-pilot/EpochPilot/series-1");

    address internal constant CANONICAL_AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    error WrongToken();
    error BadLinkGraph();

    function run() external returns (address pilot) {
        address aero = vm.envOr("AERO_TOKEN", CANONICAL_AERO);
        IERC20Meta token = IERC20Meta(aero);
        if (keccak256(bytes(token.symbol())) != keccak256("AERO")) revert WrongToken();

        address voter = IMinter(token.minter()).voter();

        // Pre-flight the same link graph the constructor will re-check.
        IVotingEscrow ve = IVotingEscrow(IVoter(voter).ve());
        if (ve.token() != aero) revert BadLinkGraph();
        if (IRewardsDistributor(ve.distributor()).ve() != address(ve)) revert BadLinkGraph();

        vm.startBroadcast();
        pilot = address(new EpochPilot{salt: SALT}(voter));
        vm.stopBroadcast();
    }
}
