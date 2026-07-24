// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @dev Self-contained minimal test harness over Foundry's raw cheatcode
///      interface. Written in-repo because this environment cannot fetch
///      forge-std (and the project's philosophy is zero external
///      dependencies anyway). Only the cheatcodes and assertions actually
///      used by this suite are declared.
interface Vm {
    function warp(uint256 newTimestamp) external;
    function roll(uint256 newHeight) external;
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function deal(address account, uint256 newBalance) external;
    function label(address account, string calldata newLabel) external;
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function createSelectFork(string calldata urlOrAlias) external returns (uint256 forkId);
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256 forkId);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function envExists(string calldata name) external view returns (bool);
    function store(address target, bytes32 slot, bytes32 value) external;
    function load(address target, bytes32 slot) external view returns (bytes32);
    function assume(bool condition) external pure;
    function skip(bool skipTest) external;
}

abstract contract TestBase {
    /// @dev keccak256("hevm cheat code") — the canonical cheatcode address.
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Aerodrome epoch length — one definition for every suite.
    uint256 internal constant WEEK = 7 days;

    function makeAddr(string memory name_) internal returns (address a) {
        a = address(uint160(uint256(keccak256(bytes(name_)))));
        vm.label(a, name_);
    }

    function _fail(string memory reason) internal pure {
        revert(reason);
    }

    function assertTrue(bool cond) internal pure {
        if (!cond) _fail("assertTrue failed");
    }

    function assertTrue(bool cond, string memory reason) internal pure {
        if (!cond) _fail(reason);
    }

    function assertFalse(bool cond) internal pure {
        if (cond) _fail("assertFalse failed");
    }

    function assertEq(uint256 a, uint256 b) internal pure {
        if (a != b) _fail(_diff("assertEq(uint) failed", a, b));
    }

    function assertEq(uint256 a, uint256 b, string memory reason) internal pure {
        if (a != b) _fail(_diff(reason, a, b));
    }

    function assertEq(address a, address b) internal pure {
        if (a != b) _fail("assertEq(address) failed");
    }

    function assertEq(bytes32 a, bytes32 b) internal pure {
        if (a != b) _fail("assertEq(bytes32) failed");
    }

    function assertEq(string memory a, string memory b) internal pure {
        if (keccak256(bytes(a)) != keccak256(bytes(b))) _fail("assertEq(string) failed");
    }

    function assertGt(uint256 a, uint256 b) internal pure {
        if (a <= b) _fail(_diff("assertGt failed", a, b));
    }

    function assertGt(uint256 a, uint256 b, string memory reason) internal pure {
        if (a <= b) _fail(_diff(reason, a, b));
    }

    function assertGe(uint256 a, uint256 b) internal pure {
        if (a < b) _fail(_diff("assertGe failed", a, b));
    }

    function assertGe(uint256 a, uint256 b, string memory reason) internal pure {
        if (a < b) _fail(_diff(reason, a, b));
    }

    function assertLt(uint256 a, uint256 b) internal pure {
        if (a >= b) _fail(_diff("assertLt failed", a, b));
    }

    function assertLe(uint256 a, uint256 b) internal pure {
        if (a > b) _fail(_diff("assertLe failed", a, b));
    }

    function assertLe(uint256 a, uint256 b, string memory reason) internal pure {
        if (a > b) _fail(_diff(reason, a, b));
    }

    /// @param maxPercentDelta 1e18 == 100%
    function assertApproxEqRel(uint256 a, uint256 b, uint256 maxPercentDelta) internal pure {
        if (b == 0) {
            if (a != 0) _fail("assertApproxEqRel failed (b == 0)");
            return;
        }
        uint256 delta = a > b ? a - b : b - a;
        if (delta * 1e18 / b > maxPercentDelta) _fail(_diff("assertApproxEqRel failed", a, b));
    }

    function assertApproxEqAbs(uint256 a, uint256 b, uint256 maxDelta) internal pure {
        uint256 delta = a > b ? a - b : b - a;
        if (delta > maxDelta) _fail(_diff("assertApproxEqAbs failed", a, b));
    }

    function _diff(string memory reason, uint256 a, uint256 b) private pure returns (string memory) {
        return string.concat(reason, ": ", _u(a), " vs ", _u(b));
    }

    function _u(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 digits;
        while (tmp != 0) {
            digits++;
            tmp /= 10;
        }
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            buf[--digits] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(buf);
    }
}
