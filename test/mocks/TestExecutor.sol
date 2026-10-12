// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC7579Execution, IERC7579Module, MODULE_TYPE_EXECUTOR} from "../../src/interfaces/IERC7579.sol";

/// @notice Bare executor module that forwards arbitrary executions (to test hooks on executeFromExecutor).
contract TestExecutor is IERC7579Module {
    function onInstall(bytes calldata) external {}

    function onUninstall(bytes calldata) external {}

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    function run(address account, bytes32 mode, bytes calldata executionCalldata) external returns (bytes[] memory) {
        return IERC7579Execution(account).executeFromExecutor(mode, executionCalldata);
    }
}
