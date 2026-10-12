// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Execution, MODE_BATCH_DEFAULT, MODE_SINGLE_DEFAULT} from "../../src/interfaces/IERC7579.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice Shared actors and helpers for unit, fuzz and invariant tests.
abstract contract BaseTest is Test {
    uint256 internal constant USDC_UNIT = 1e6;
    /// @dev Fixed, comfortably-past start time so `block.timestamp - x` arithmetic in tests never underflows.
    uint256 internal constant T0 = 1_760_000_000; // 2025-10-09

    MockUSDC internal usdc;

    address internal payer = makeAddr("payer");
    address internal payee = makeAddr("payee");
    address internal arbiter = makeAddr("arbiter");
    address internal validator = makeAddr("validator");
    address internal stranger = makeAddr("stranger");
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal entryPoint = makeAddr("entryPoint");

    function setUp() public virtual {
        vm.warp(T0);
        usdc = new MockUSDC();
        vm.label(address(usdc), "USDC");
    }

    // ------------------------------------------------------------------ token helpers

    function _fund(address to, uint256 amount) internal {
        usdc.mint(to, amount);
    }

    function _fundAndApprove(address from, address spender, uint256 amount) internal {
        usdc.mint(from, amount);
        vm.prank(from);
        usdc.approve(spender, amount);
    }

    // ------------------------------------------------------------------ ERC-7579 encoding helpers

    function _single(address target, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(target, value, data);
    }

    function _batch(Execution[] memory executions) internal pure returns (bytes memory) {
        return abi.encode(executions);
    }

    function _mode(bytes1 callType, bytes1 execType) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(callType, execType, bytes30(0)));
    }

    function _singleMode() internal pure returns (bytes32) {
        return MODE_SINGLE_DEFAULT;
    }

    function _batchMode() internal pure returns (bytes32) {
        return MODE_BATCH_DEFAULT;
    }

    // ------------------------------------------------------------------ signature helpers

    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _today() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function _nextUtcDay() internal {
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
    }
}
