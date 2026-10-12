// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title IAgentPolicyHook
/// @notice Types, events, errors and functions of the Agent Bank ERC-7579 spend-policy hook.
interface IAgentPolicyHook {
    /// @notice How the hook treats calls to an allowlisted contract.
    /// @dev Kinds other than Generic make the hook understand that contract's payment functions, so that the
    ///      recipient allowlist also covers funds routed through it (escrow payees, stream payees, vault owners).
    enum ContractKind {
        None, // not allowlisted
        Generic, // any call allowed; may be an ERC-20 spender; trusted to route funds
        AgentEscrow, // `lock` payee must pass the recipient allowlist
        PaymentStreams, // `createStream` payee must pass the recipient allowlist
        TimeLockVaults // `deposit` target vault's parent account must pass the recipient allowlist
    }

    /// @notice Per-token caps. `maxPerTx` bounds the sum of a token's outflows in one hooked execution
    ///         (single or batch); `maxPerDay` bounds the sum per UTC day. Both 0 = token not configured.
    struct TokenLimitConfig {
        address token; // address(0) = native ETH
        uint128 maxPerTx;
        uint128 maxPerDay;
    }

    /// @notice One allowlisted contract.
    struct ContractConfig {
        address target;
        ContractKind kind;
    }

    /// @notice Bulk configuration (install data and `applyConfig`). Entries are applied in order.
    struct PolicyConfig {
        TokenLimitConfig[] tokenLimits;
        address[] allowedRecipients;
        ContractConfig[] allowedContracts;
        bool recipientAllowlistEnabled;
    }

    /// @notice The hook was installed on `account`; configuration lives under `epoch`.
    event PolicyInstalled(address indexed account, uint64 epoch);
    /// @notice The hook was uninstalled from `account`; configuration of `epoch` is discarded.
    event PolicyUninstalled(address indexed account, uint64 epoch);
    /// @notice Token caps changed (both 0 = removed).
    event TokenLimitSet(address indexed account, address indexed token, uint128 maxPerTx, uint128 maxPerDay);
    /// @notice A recipient was added to or removed from the allowlist.
    event RecipientSet(address indexed account, address indexed recipient, bool allowed);
    /// @notice The recipient allowlist was switched on or off.
    event RecipientAllowlistSet(address indexed account, bool enabled);
    /// @notice A contract was allowlisted (kind != None) or removed (kind == None).
    event ContractSet(address indexed account, address indexed target, ContractKind kind);
    /// @notice An execution consumed `amount` of the daily cap; `spentToday` is the new UTC-day total.
    event SpendRecorded(address indexed account, address indexed token, uint256 amount, uint256 spentToday);

    error NotInitialized(address account);
    error AlreadyInitialized(address account);
    error InvalidTokenLimit(address token, uint128 maxPerTx, uint128 maxPerDay);
    error InvalidAddress(address target);
    error UnsupportedCallType(bytes1 callType);
    error UnsupportedExecType(bytes1 execType);
    error UnsupportedModeSelector(bytes4 modeSelector);
    error MalformedExecution();
    error HookCallBlocked();
    error TargetNotAllowed(address target);
    error UnsupportedTokenCall(address token, bytes4 selector);
    error RecipientNotAllowed(address recipient);
    error SpenderNotAllowed(address spender);
    error TokenNotConfigured(address token);
    error PerTxLimitExceeded(address token, uint256 amount, uint256 limit);
    error DailyLimitExceeded(address token, uint256 spentToday, uint256 limit);

    /// @notice Applies a bulk configuration to the caller's policy.
    function applyConfig(PolicyConfig calldata config) external;

    /// @notice Sets the caller's caps for `token` (both 0 removes it).
    function setTokenLimit(address token, uint128 maxPerTx, uint128 maxPerDay) external;

    /// @notice Adds or removes `recipient` from the caller's recipient allowlist.
    function setRecipient(address recipient, bool allowed) external;

    /// @notice Turns the caller's recipient allowlist on or off.
    function setRecipientAllowlistEnabled(bool enabled) external;

    /// @notice Allowlists `target` with `kind`, or removes it with `ContractKind.None`.
    function setContract(address target, ContractKind kind) external;

    /// @notice Whether the hook is installed (initialised) for `account`.
    function isInitialized(address account) external view returns (bool);

    /// @notice Whether `account`'s recipient allowlist is enabled.
    function recipientAllowlistEnabled(address account) external view returns (bool);

    /// @notice `account`'s caps for `token`.
    function tokenLimit(address account, address token) external view returns (uint128 maxPerTx, uint128 maxPerDay);

    /// @notice Amount of `token` `account` has spent in the current UTC day.
    function spentToday(address account, address token) external view returns (uint256);

    /// @notice Amount of `token` `account` may still spend in the current UTC day.
    function remainingToday(address account, address token) external view returns (uint256);

    /// @notice Whether `recipient` is on `account`'s explicit recipient allowlist.
    function isRecipientAllowed(address account, address recipient) external view returns (bool);

    /// @notice How `account` allowlisted `target` (None if not allowlisted).
    function contractKind(address account, address target) external view returns (ContractKind);
}
