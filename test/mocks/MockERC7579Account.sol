// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {
    CALLTYPE_BATCH,
    CALLTYPE_DELEGATECALL,
    CALLTYPE_SINGLE,
    EXECTYPE_DEFAULT,
    EXECTYPE_TRY,
    Execution,
    IERC7579Hook,
    IERC7579Module,
    MODULE_TYPE_EXECUTOR,
    MODULE_TYPE_HOOK
} from "../../src/interfaces/IERC7579.sol";

/// @title MockERC7579Account
/// @notice Minimal ERC-7579 smart account for tests. It mirrors the Safe7579 behaviour the modules depend on:
///         - `execute` is callable by the entry point or the account itself and is wrapped by the global hook, which
///           receives the full `msg.data`;
///         - `executeFromExecutor` is callable only by installed executors and is also hooked;
///         - `installModule`/`uninstallModule` are hooked; `onUninstall` is try-called; `postCheck` is still called
///           on a hook that uninstalled itself;
///         - single = abi.encodePacked(target, value, callData); batch = abi.encode(Execution[]); delegatecall and
///           try-mode are supported;
///         - `ownerExecute` models the Safe's native `execTransaction`: owner-authorised and NOT hooked;
///         - ERC-1271 accepts ECDSA signatures from the owner or from keys granted 1271 rights (to model a session
///           key with ERC-1271 permissions in the spike demonstration).
contract MockERC7579Account {
    address public immutable entryPoint;
    address public owner;
    address public hook;
    mapping(address module => bool) public isExecutor;
    mapping(address signer => bool) public isErc1271Signer;

    /// @notice Emitted for each failed call in try-mode.
    event TryExecutionFailed(uint256 index, bytes result);

    error Unauthorized(address caller);
    error UnsupportedCallType(bytes1 callType);
    error UnsupportedExecType(bytes1 execType);
    error UnsupportedModuleType(uint256 moduleTypeId);
    error ModuleTypeMismatch(address module, uint256 moduleTypeId);
    error HookAlreadyInstalled(address hook);
    error ModuleNotInstalled(address module);

    constructor(address entryPoint_, address owner_) {
        entryPoint = entryPoint_;
        owner = owner_;
    }

    receive() external payable {}

    modifier onlyEntryPointOrSelf() {
        if (msg.sender != entryPoint && msg.sender != address(this)) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyExecutor() {
        if (!isExecutor[msg.sender]) revert Unauthorized(msg.sender);
        _;
    }

    modifier withHook() {
        address h = hook;
        bytes memory hookData;
        if (h != address(0)) hookData = IERC7579Hook(h).preCheck(msg.sender, msg.value, msg.data);
        _;
        if (h != address(0)) IERC7579Hook(h).postCheck(hookData);
    }

    // ------------------------------------------------------------------ ERC-7579 execution

    function execute(bytes32 mode, bytes calldata executionCalldata) external payable onlyEntryPointOrSelf withHook {
        _execute(mode, executionCalldata);
    }

    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)
        external
        payable
        onlyExecutor
        withHook
        returns (bytes[] memory returnData)
    {
        return _execute(mode, executionCalldata);
    }

    // ------------------------------------------------------------------ ERC-7579 module management

    function installModule(uint256 moduleTypeId, address module, bytes calldata initData)
        external
        payable
        onlyEntryPointOrSelf
        withHook
    {
        if (!IERC7579Module(module).isModuleType(moduleTypeId)) revert ModuleTypeMismatch(module, moduleTypeId);
        if (moduleTypeId == MODULE_TYPE_HOOK) {
            if (hook != address(0)) revert HookAlreadyInstalled(hook);
            hook = module;
        } else if (moduleTypeId == MODULE_TYPE_EXECUTOR) {
            isExecutor[module] = true;
        } else {
            revert UnsupportedModuleType(moduleTypeId);
        }
        IERC7579Module(module).onInstall(initData);
    }

    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData)
        external
        payable
        onlyEntryPointOrSelf
        withHook
    {
        if (moduleTypeId == MODULE_TYPE_HOOK) {
            if (hook != module) revert ModuleNotInstalled(module);
            hook = address(0);
        } else if (moduleTypeId == MODULE_TYPE_EXECUTOR) {
            if (!isExecutor[module]) revert ModuleNotInstalled(module);
            isExecutor[module] = false;
        } else {
            revert UnsupportedModuleType(moduleTypeId);
        }
        // Like Safe7579: a module cannot block its own removal.
        try IERC7579Module(module).onUninstall(deInitData) {} catch {}
    }

    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata) external view returns (bool) {
        if (moduleTypeId == MODULE_TYPE_HOOK) return hook == module && module != address(0);
        if (moduleTypeId == MODULE_TYPE_EXECUTOR) return isExecutor[module];
        return false;
    }

    // ------------------------------------------------------------------ owner path (Safe execTransaction model)

    /// @notice The owner's native path: executes directly, never through ERC-7579 hooks.
    function ownerExecute(address target, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) _bubble(ret);
        return ret;
    }

    /// @notice Grants or revokes ERC-1271 signing rights to `signer` (only via the account itself, i.e. owner path).
    function setErc1271Signer(address signer, bool allowed) external {
        if (msg.sender != address(this)) revert Unauthorized(msg.sender);
        isErc1271Signer[signer] = allowed;
    }

    // ------------------------------------------------------------------ ERC-1271

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && (recovered == owner || isErc1271Signer[recovered])) {
            return 0x1626ba7e;
        }
        return 0xffffffff;
    }

    // ------------------------------------------------------------------ internals

    function _execute(bytes32 mode, bytes calldata data) internal returns (bytes[] memory results) {
        bytes1 callType = bytes1(mode);
        bytes1 execType = bytes1(mode << 8);
        bool tryMode;
        if (execType == EXECTYPE_TRY) tryMode = true;
        else if (execType != EXECTYPE_DEFAULT) revert UnsupportedExecType(execType);

        if (callType == CALLTYPE_BATCH) {
            Execution[] memory executions = abi.decode(data, (Execution[]));
            results = new bytes[](executions.length);
            for (uint256 i; i < executions.length; ++i) {
                results[i] = _call(executions[i].target, executions[i].value, executions[i].callData, tryMode, i);
            }
        } else if (callType == CALLTYPE_SINGLE) {
            results = new bytes[](1);
            results[0] = _call(address(bytes20(data[:20])), uint256(bytes32(data[20:52])), data[52:], tryMode, 0);
        } else if (callType == CALLTYPE_DELEGATECALL) {
            results = new bytes[](1);
            (bool ok, bytes memory ret) = address(bytes20(data[:20])).delegatecall(data[20:]);
            if (!ok && !tryMode) _bubble(ret);
            results[0] = ret;
        } else {
            revert UnsupportedCallType(callType);
        }
    }

    function _call(address target, uint256 value, bytes memory callData, bool tryMode, uint256 index)
        internal
        returns (bytes memory ret)
    {
        bool ok;
        (ok, ret) = target.call{value: value}(callData);
        if (!ok) {
            if (!tryMode) _bubble(ret);
            emit TryExecutionFailed(index, ret);
        }
    }

    function _bubble(bytes memory ret) internal pure {
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }
}
