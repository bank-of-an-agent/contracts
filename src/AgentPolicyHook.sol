// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IAgentEscrow} from "./interfaces/IAgentEscrow.sol";
import {IAgentPolicyHook} from "./interfaces/IAgentPolicyHook.sol";
import {
    CALLTYPE_BATCH,
    CALLTYPE_SINGLE,
    EXECTYPE_DEFAULT,
    EXECTYPE_TRY,
    Execution,
    IERC7579Execution,
    IERC7579Hook,
    MODULE_TYPE_HOOK
} from "./interfaces/IERC7579.sol";
import {IPaymentStreams} from "./interfaces/IPaymentStreams.sol";
import {ITimeLockVaults} from "./interfaces/ITimeLockVaults.sol";

/// @title AgentPolicyHook
/// @author Agent Bank
/// @notice ERC-7579 hook (module type 4): a second, on-chain spend layer for agent smart accounts, behind the
///         session-key scope. For every `execute` / `executeFromExecutor` it decodes the single or batch executions
///         and enforces the account's own policy:
///         - per-token caps: `maxPerTx` (sum of a token's outflows in one hooked execution) and `maxPerDay`
///           (UTC-day buckets); ERC-20 `transfer`/`transferFrom` amounts, `approve`/`increaseAllowance` amounts and
///           native value all count;
///         - fail closed: a call may only target the account itself, a configured token (with the ERC-20 selectors
///           above, plus `decreaseAllowance`), an allowlisted contract, or receive plain native value;
///         - approvals only to allowlisted contracts; optional recipient allowlist for transfers, native value and
///           (for known Agent Bank contracts) escrow/stream payees and vault deposits.
///
///         Configuration is set ONLY by the account itself (`msg.sender == account`): through `onInstall` data, or by
///         the owner calling the config functions directly with the Safe's native `execTransaction`. Calls to this hook
///         through the hooked execution path (the path session keys use) are rejected, so an agent can never loosen
///         its own limits even if its session scope mistakenly allowed calling this contract.
///
///         THIS HOOK CAN NEVER TRAP FUNDS. The owner's exit path is the Safe's native `execTransaction`, which does not
///         pass through ERC-7579 hooks. Module management (install/uninstall via the account) is always allowed, and
///         uninstalling never depends on this hook's state.
/// @dev Scope and residual risk (see AUDIT_SCOPE.md):
///      - Calls targeting the account itself are allowed (module management). Validators must never let session keys
///        call the account itself: with that power a key could uninstall this hook.
///      - The hook sees only executions. Signature-based pulls (EIP-3009, EIP-2612 permit via ERC-1271) bypass it;
///        agent sessions must not have ERC-1271 rights (ADR 0001).
///      - Generic allowlisted contracts are trusted to route the funds approved to them.
///      - Per-tx caps apply per hooked execution; nested self-executions are each checked separately (the daily
///        cap is the hard bound).
///      Storage is keyed by (account, epoch); uninstalling bumps the epoch, discarding all configuration and windows.
contract AgentPolicyHook is IAgentPolicyHook, IERC7579Hook {
    /// @notice Pseudo-token address used to cap native ETH value.
    address public constant NATIVE_TOKEN = address(0);

    bytes4 private constant ERC20_TRANSFER = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant ERC20_TRANSFER_FROM = 0x23b872dd; // transferFrom(address,address,uint256)
    bytes4 private constant ERC20_APPROVE = 0x095ea7b3; // approve(address,uint256)
    bytes4 private constant ERC20_INCREASE_ALLOWANCE = 0x39509351; // increaseAllowance(address,uint256)
    bytes4 private constant ERC20_DECREASE_ALLOWANCE = 0xa457c2d7; // decreaseAllowance(address,uint256)

    struct AccountState {
        bool initialized;
        bool recipientAllowlistEnabled;
        uint64 epoch;
    }

    struct Limit {
        uint128 maxPerTx;
        uint128 maxPerDay;
    }

    struct Window {
        uint64 day; // UTC day index: block.timestamp / 1 days
        uint192 spent;
    }

    mapping(address account => AccountState) private _accounts;
    mapping(address account => mapping(uint64 epoch => mapping(address token => Limit))) private _limits;
    mapping(address account => mapping(uint64 epoch => mapping(address token => Window))) private _windows;
    mapping(address account => mapping(uint64 epoch => mapping(address recipient => bool))) private _recipients;
    mapping(address account => mapping(uint64 epoch => mapping(address target => ContractKind))) private _contracts;

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-7579 module lifecycle
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Installs the policy for the calling account.
    /// @param data Empty (start fully locked down) or `abi.encode(PolicyConfig)`.
    function onInstall(bytes calldata data) external {
        AccountState storage st = _accounts[msg.sender];
        if (st.initialized) revert AlreadyInitialized(msg.sender);
        st.initialized = true;
        uint64 epoch = st.epoch;
        emit PolicyInstalled(msg.sender, epoch);
        if (data.length != 0) _applyConfig(msg.sender, epoch, abi.decode(data, (PolicyConfig)));
    }

    /// @notice Uninstalls the policy for the calling account, discarding its configuration. Never reverts.
    function onUninstall(bytes calldata) external {
        AccountState storage st = _accounts[msg.sender];
        if (!st.initialized) return;
        uint64 epoch = st.epoch;
        st.initialized = false;
        st.recipientAllowlistEnabled = false;
        st.epoch = epoch + 1;
        emit PolicyUninstalled(msg.sender, epoch);
    }

    /// @notice ERC-7579 module type check: this is a hook (type 4) only.
    /// @param moduleTypeId Module type id.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_HOOK;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-7579 hook
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Enforces the calling account's policy on `execute` / `executeFromExecutor`. Other account functions
    ///         (module management, fallbacks) pass through untouched, so the hook can always be uninstalled.
    /// @param msgData Full calldata of the account call being hooked.
    /// @return hookData Always empty.
    function preCheck(address, uint256, bytes calldata msgData) external returns (bytes memory hookData) {
        if (msgData.length < 4) return hookData;
        bytes4 selector = bytes4(msgData[:4]);
        if (
            selector != IERC7579Execution.execute.selector && selector != IERC7579Execution.executeFromExecutor.selector
        ) {
            return hookData;
        }
        AccountState memory st = _accounts[msg.sender];
        if (!st.initialized) revert NotInitialized(msg.sender); // fail closed
        (bytes32 mode, bytes memory executionCalldata) = abi.decode(msgData[4:], (bytes32, bytes));
        _enforce(msg.sender, st, _decodeExecutions(mode, executionCalldata));
    }

    /// @notice No post-execution checks. Never reverts (the account may call it after this hook uninstalled itself).
    // forge-lint: disable-next-line(empty-block)
    function postCheck(bytes calldata) external pure {}

    // ---------------------------------------------------------------------------------------------------------------
    // Configuration (msg.sender == account)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Applies a bulk configuration to the caller's policy.
    /// @param config Token limits, recipients and contracts to set, and the recipient-allowlist switch.
    function applyConfig(PolicyConfig calldata config) external {
        _applyConfig(msg.sender, _requireInitialized(msg.sender), config);
    }

    /// @notice Sets the caller's caps for `token` (address(0) = native ETH). Both 0 removes the token.
    /// @param token Token to cap.
    /// @param maxPerTx Max outflow per hooked execution (0 < maxPerTx <= maxPerDay unless removing).
    /// @param maxPerDay Max outflow per UTC day.
    function setTokenLimit(address token, uint128 maxPerTx, uint128 maxPerDay) external {
        _setTokenLimit(msg.sender, _requireInitialized(msg.sender), token, maxPerTx, maxPerDay);
    }

    /// @notice Adds or removes `recipient` from the caller's recipient allowlist.
    /// @param recipient Recipient address (non-zero).
    /// @param allowed True to add, false to remove.
    function setRecipient(address recipient, bool allowed) external {
        _setRecipient(msg.sender, _requireInitialized(msg.sender), recipient, allowed);
    }

    /// @notice Turns the caller's recipient allowlist on or off.
    /// @param enabled True to enforce the allowlist.
    function setRecipientAllowlistEnabled(bool enabled) external {
        _requireInitialized(msg.sender);
        _accounts[msg.sender].recipientAllowlistEnabled = enabled;
        emit RecipientAllowlistSet(msg.sender, enabled);
    }

    /// @notice Allowlists `target` as `kind`, or removes it with `ContractKind.None`.
    /// @param target Contract address (non-zero, not the caller, not this hook).
    /// @param kind How calls to `target` are interpreted.
    function setContract(address target, ContractKind kind) external {
        _setContract(msg.sender, _requireInitialized(msg.sender), target, kind);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAgentPolicyHook
    function isInitialized(address account) external view returns (bool) {
        return _accounts[account].initialized;
    }

    /// @inheritdoc IAgentPolicyHook
    function recipientAllowlistEnabled(address account) external view returns (bool) {
        return _accounts[account].recipientAllowlistEnabled;
    }

    /// @inheritdoc IAgentPolicyHook
    function tokenLimit(address account, address token) external view returns (uint128 maxPerTx, uint128 maxPerDay) {
        Limit memory limit = _limits[account][_accounts[account].epoch][token];
        return (limit.maxPerTx, limit.maxPerDay);
    }

    /// @inheritdoc IAgentPolicyHook
    function spentToday(address account, address token) public view returns (uint256) {
        Window memory w = _windows[account][_accounts[account].epoch][token];
        return w.day == _today() ? w.spent : 0;
    }

    /// @inheritdoc IAgentPolicyHook
    function remainingToday(address account, address token) external view returns (uint256) {
        uint256 maxPerDay = _limits[account][_accounts[account].epoch][token].maxPerDay;
        uint256 spent = spentToday(account, token);
        return spent >= maxPerDay ? 0 : maxPerDay - spent;
    }

    /// @inheritdoc IAgentPolicyHook
    function isRecipientAllowed(address account, address recipient) external view returns (bool) {
        return _recipients[account][_accounts[account].epoch][recipient];
    }

    /// @inheritdoc IAgentPolicyHook
    function contractKind(address account, address target) external view returns (ContractKind) {
        return _contracts[account][_accounts[account].epoch][target];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Enforcement
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Mirrors how ERC-7579 accounts (Safe7579, the reference implementation) decode executions. Anything else
    ///      (delegatecall, staticcall, custom mode selectors, unknown exec types) is rejected.
    function _decodeExecutions(bytes32 mode, bytes memory executionCalldata)
        private
        pure
        returns (Execution[] memory executions)
    {
        // Field extraction from the ERC-7579 mode word: truncation is the point.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes1 callType = bytes1(mode);
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes1 execType = bytes1(mode << 8);
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 modeSelector = bytes4(mode << 48);
        if (execType != EXECTYPE_DEFAULT && execType != EXECTYPE_TRY) revert UnsupportedExecType(execType);
        if (modeSelector != bytes4(0)) revert UnsupportedModeSelector(modeSelector);

        if (callType == CALLTYPE_BATCH) {
            executions = abi.decode(executionCalldata, (Execution[]));
        } else if (callType == CALLTYPE_SINGLE) {
            // abi.encodePacked(address target, uint256 value, bytes callData)
            uint256 length = executionCalldata.length;
            if (length < 52) revert MalformedExecution();
            address target;
            uint256 value;
            bytes memory callData = new bytes(length - 52);
            assembly ("memory-safe") {
                let src := add(executionCalldata, 0x20)
                target := shr(96, mload(src))
                value := mload(add(src, 20))
                mcopy(add(callData, 0x20), add(src, 52), sub(length, 52))
            }
            executions = new Execution[](1);
            executions[0] = Execution(target, value, callData);
        } else {
            revert UnsupportedCallType(callType);
        }
    }

    /// @dev Classifies every execution, aggregates outflows per token, then applies per-tx and daily caps.
    function _enforce(address account, AccountState memory st, Execution[] memory executions) private {
        uint256 n = executions.length;
        address[] memory tokens = new address[](2 * n);
        uint256[] memory amounts = new uint256[](2 * n);
        uint256 count = 0;
        for (uint256 i; i < n; ++i) {
            (address token, uint256 amount, uint256 nativeAmount) = _classify(account, st, executions[i]);
            if (nativeAmount != 0) count = _accumulate(tokens, amounts, count, NATIVE_TOKEN, nativeAmount);
            if (amount != 0) count = _accumulate(tokens, amounts, count, token, amount);
        }
        for (uint256 j; j < count; ++j) {
            _consume(account, st.epoch, tokens[j], amounts[j]);
        }
    }

    /// @dev Returns the ERC-20 outflow (`token`, `amount`) and native outflow of one execution, or reverts.
    function _classify(address account, AccountState memory st, Execution memory execution)
        private
        view
        returns (address token, uint256 amount, uint256 nativeAmount)
    {
        address target = execution.target;
        // Account management (module install/uninstall etc.) — see the residual-risk note in the contract docs.
        if (target == account) return (address(0), 0, 0);
        // Policy changes must come from the owner's native path, never from the hooked path session keys use.
        if (target == address(this)) revert HookCallBlocked();

        if (execution.value != 0) {
            _requireRecipient(account, st, target);
            nativeAmount = execution.value;
        }

        bytes memory data = execution.callData;
        if (target != NATIVE_TOKEN && _limits[account][st.epoch][target].maxPerDay != 0) {
            (token, amount) = _classifyTokenCall(account, st, target, data);
            return (token, amount, nativeAmount);
        }
        ContractKind kind = _contracts[account][st.epoch][target];
        if (kind != ContractKind.None) {
            _checkContractCall(account, st, target, kind, data);
            return (address(0), 0, nativeAmount);
        }
        if (data.length == 0) return (address(0), 0, nativeAmount); // plain native transfer
        revert TargetNotAllowed(target);
    }

    function _classifyTokenCall(address account, AccountState memory st, address token, bytes memory data)
        private
        view
        returns (address, uint256)
    {
        if (data.length < 4) revert UnsupportedTokenCall(token, bytes4(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = bytes4(data); // first 4 bytes = function selector (length checked above)

        if (selector == ERC20_TRANSFER) {
            address to = _addressArg(data, 0);
            uint256 amount = _uintArg(data, 1);
            if (to == account) return (token, 0);
            _requireRecipient(account, st, to);
            return (token, amount);
        }
        if (selector == ERC20_TRANSFER_FROM) {
            _addressArg(data, 0); // `from`: validated for encoding only
            address to = _addressArg(data, 1);
            uint256 amount = _uintArg(data, 2);
            // Pulling into the account (e.g. sweeping an agent's spend-key float back) is an inflow.
            if (to == account) return (token, 0);
            _requireRecipient(account, st, to);
            return (token, amount);
        }
        if (selector == ERC20_APPROVE || selector == ERC20_INCREASE_ALLOWANCE) {
            address spender = _addressArg(data, 0);
            uint256 amount = _uintArg(data, 1);
            if (amount == 0) return (token, 0); // revoking (or a no-op increase) is always allowed
            if (_contracts[account][st.epoch][spender] == ContractKind.None) revert SpenderNotAllowed(spender);
            return (token, amount); // an allowance is a future outflow: it counts against the caps now
        }
        if (selector == ERC20_DECREASE_ALLOWANCE) {
            _addressArg(data, 0);
            _uintArg(data, 1);
            return (token, 0);
        }
        revert UnsupportedTokenCall(token, selector);
    }

    /// @dev For known Agent Bank contracts, make the recipient allowlist cover the payee of funds routed through them.
    function _checkContractCall(
        address account,
        AccountState memory st,
        address target,
        ContractKind kind,
        bytes memory data
    ) private view {
        if (!st.recipientAllowlistEnabled || kind == ContractKind.Generic || data.length < 4) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = bytes4(data); // first 4 bytes = function selector (length checked above)
        if (kind == ContractKind.AgentEscrow) {
            // lock(token, payee, ...)
            if (selector == IAgentEscrow.lock.selector) _requireRecipient(account, st, _addressArg(data, 1));
        } else if (kind == ContractKind.PaymentStreams) {
            // createStream(token, payee, ...)
            if (selector == IPaymentStreams.createStream.selector) {
                _requireRecipient(account, st, _addressArg(data, 1));
            }
        } else if (kind == ContractKind.TimeLockVaults) {
            // deposit(id, amount): funds can only ever leave a vault to its parent account
            if (selector == ITimeLockVaults.deposit.selector) {
                // View call (STATICCALL) to a contract the account owner allowlisted; a batch only burns its own gas.
                // forge-lint: disable-next-line(calls-loop)
                _requireRecipient(account, st, ITimeLockVaults(target).vaultAccount(_uintArg(data, 0)));
            }
        }
    }

    function _requireRecipient(address account, AccountState memory st, address recipient) private view {
        if (!st.recipientAllowlistEnabled || recipient == account) return;
        if (_recipients[account][st.epoch][recipient]) return;
        if (_contracts[account][st.epoch][recipient] != ContractKind.None) return;
        revert RecipientNotAllowed(recipient);
    }

    function _accumulate(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 count,
        address token,
        uint256 amount
    ) private pure returns (uint256) {
        for (uint256 i; i < count; ++i) {
            if (tokens[i] == token) {
                amounts[i] += amount;
                return count;
            }
        }
        tokens[count] = token;
        amounts[count] = amount;
        return count + 1;
    }

    function _consume(address account, uint64 epoch, address token, uint256 amount) private {
        Limit memory limit = _limits[account][epoch][token];
        if (limit.maxPerDay == 0) revert TokenNotConfigured(token);
        if (amount > limit.maxPerTx) revert PerTxLimitExceeded(token, amount, limit.maxPerTx);

        Window storage window = _windows[account][epoch][token];
        uint64 today = _today();
        uint256 newSpent = (window.day == today ? uint256(window.spent) : 0) + amount;
        if (newSpent > limit.maxPerDay) revert DailyLimitExceeded(token, newSpent, limit.maxPerDay);
        window.day = today;
        // forge-lint: disable-next-line(unsafe-typecast)
        window.spent = uint192(newSpent); // <= maxPerDay <= uint128 max
        // The only external calls before this point are view calls (STATICCALL) to allowlisted vault registries.
        // forge-lint: disable-next-line(reentrancy-events)
        emit SpendRecorded(account, token, amount, newSpent);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Configuration internals
    // ---------------------------------------------------------------------------------------------------------------

    function _requireInitialized(address account) private view returns (uint64 epoch) {
        AccountState memory st = _accounts[account];
        if (!st.initialized) revert NotInitialized(account);
        return st.epoch;
    }

    function _applyConfig(address account, uint64 epoch, PolicyConfig memory config) private {
        for (uint256 i; i < config.tokenLimits.length; ++i) {
            TokenLimitConfig memory l = config.tokenLimits[i];
            _setTokenLimit(account, epoch, l.token, l.maxPerTx, l.maxPerDay);
        }
        for (uint256 i; i < config.allowedRecipients.length; ++i) {
            _setRecipient(account, epoch, config.allowedRecipients[i], true);
        }
        for (uint256 i; i < config.allowedContracts.length; ++i) {
            ContractConfig memory c = config.allowedContracts[i];
            _setContract(account, epoch, c.target, c.kind);
        }
        _accounts[account].recipientAllowlistEnabled = config.recipientAllowlistEnabled;
        emit RecipientAllowlistSet(account, config.recipientAllowlistEnabled);
    }

    function _setTokenLimit(address account, uint64 epoch, address token, uint128 maxPerTx, uint128 maxPerDay) private {
        if (token == account || token == address(this)) revert InvalidAddress(token);
        bool removing = maxPerTx == 0 && maxPerDay == 0;
        if (!removing && (maxPerTx == 0 || maxPerTx > maxPerDay)) revert InvalidTokenLimit(token, maxPerTx, maxPerDay);
        _limits[account][epoch][token] = Limit(maxPerTx, maxPerDay);
        emit TokenLimitSet(account, token, maxPerTx, maxPerDay);
    }

    function _setRecipient(address account, uint64 epoch, address recipient, bool allowed) private {
        if (recipient == address(0)) revert InvalidAddress(recipient);
        _recipients[account][epoch][recipient] = allowed;
        emit RecipientSet(account, recipient, allowed);
    }

    function _setContract(address account, uint64 epoch, address target, ContractKind kind) private {
        if (target == address(0) || target == account || target == address(this)) revert InvalidAddress(target);
        _contracts[account][epoch][target] = kind;
        emit ContractSet(account, target, kind);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Calldata helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The `index`-th 32-byte argument after the 4-byte selector; reverts if the calldata is too short.
    function _uintArg(bytes memory data, uint256 index) private pure returns (uint256 word) {
        if (data.length < 4 + 32 * (index + 1)) revert MalformedExecution();
        assembly ("memory-safe") {
            word := mload(add(add(data, 36), mul(index, 32)))
        }
    }

    /// @dev Like `_uintArg` but requires a clean address (upper 96 bits zero), as Solidity's ABI decoder does.
    function _addressArg(bytes memory data, uint256 index) private pure returns (address) {
        uint256 word = _uintArg(data, index);
        if (word >> 160 != 0) revert MalformedExecution();
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }

    function _today() private view returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.timestamp / 1 days);
    }
}
