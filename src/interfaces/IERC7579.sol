// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @dev Minimal ERC-7579 surface (https://eips.ethereum.org/EIPS/eip-7579), defined locally to avoid heavyweight
///      dependencies. Selectors and encodings match the spec and the Safe7579 adapter.

/// @dev Module type ids.
uint256 constant MODULE_TYPE_VALIDATOR = 1;
uint256 constant MODULE_TYPE_EXECUTOR = 2;
uint256 constant MODULE_TYPE_FALLBACK = 3;
uint256 constant MODULE_TYPE_HOOK = 4;

/// @dev Call types (first byte of the execution mode).
bytes1 constant CALLTYPE_SINGLE = 0x00;
bytes1 constant CALLTYPE_BATCH = 0x01;
bytes1 constant CALLTYPE_STATIC = 0xFE;
bytes1 constant CALLTYPE_DELEGATECALL = 0xFF;

/// @dev Exec types (second byte of the execution mode).
bytes1 constant EXECTYPE_DEFAULT = 0x00;
bytes1 constant EXECTYPE_TRY = 0x01;

/// @dev Default-mode single and batch calls (revert on failure, no mode selector, no payload).
bytes32 constant MODE_SINGLE_DEFAULT = bytes32(0);
bytes32 constant MODE_BATCH_DEFAULT = bytes32(uint256(1) << 248);

/// @notice One call in an ERC-7579 batch. Batches are `abi.encode(Execution[])`; single calls are
///         `abi.encodePacked(target, value, callData)`.
struct Execution {
    address target;
    uint256 value;
    bytes callData;
}

/// @notice Interface every ERC-7579 module implements.
interface IERC7579Module {
    /// @notice Called by the account when the module is installed.
    /// @param data Module-specific initialisation data.
    function onInstall(bytes calldata data) external;

    /// @notice Called by the account when the module is uninstalled.
    /// @param data Module-specific de-initialisation data.
    function onUninstall(bytes calldata data) external;

    /// @notice Whether the module is of the given ERC-7579 module type.
    /// @param moduleTypeId The module type id.
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
}

/// @notice ERC-7579 hook module (type 4).
interface IERC7579Hook is IERC7579Module {
    /// @notice Called by the account before executing `msgData`.
    /// @param msgSender Caller of the account function.
    /// @param msgValue Value sent to the account function.
    /// @param msgData Full calldata of the account function (selector included).
    /// @return hookData Data handed back to `postCheck`.
    function preCheck(address msgSender, uint256 msgValue, bytes calldata msgData)
        external
        returns (bytes memory hookData);

    /// @notice Called by the account after the execution.
    /// @param hookData Data returned by `preCheck`.
    function postCheck(bytes calldata hookData) external;
}

/// @notice ERC-7579 account execution surface.
interface IERC7579Execution {
    /// @notice Executes `executionCalldata` according to `mode` (called by the entry point or the account).
    function execute(bytes32 mode, bytes calldata executionCalldata) external payable;

    /// @notice Executes on behalf of an installed executor module.
    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)
        external
        payable
        returns (bytes[] memory returnData);
}

/// @notice ERC-7579 account module-management surface.
interface IERC7579ModuleConfig {
    /// @notice Installs a module of the given type.
    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external payable;

    /// @notice Uninstalls a module of the given type.
    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) external payable;

    /// @notice Whether a module is installed.
    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata additionalContext)
        external
        view
        returns (bool);
}
