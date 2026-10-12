// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title ITopUpExecutor
/// @notice Types, events, errors and functions of the Agent Bank treasury auto-top-up ERC-7579 executor.
interface ITopUpExecutor {
    /// @notice A treasury's standing refill rule for one agent account (set only by the treasury itself).
    struct TopUpRule {
        address token; // asset to refill (e.g. USDC); address(0) = no rule
        uint128 refillTo; // target agent balance after a top-up
        uint128 whenBelow; // top up only while the agent balance is strictly below this (<= refillTo)
        uint128 maxPerDay; // cap on top-ups to this agent per UTC day, in token units
    }

    /// @notice One entry of the install data.
    struct RuleInit {
        address agent;
        TopUpRule rule;
    }

    /// @notice The executor was installed on `treasury`; rules live under `epoch`.
    event TopUpInstalled(address indexed treasury, uint64 epoch);
    /// @notice The executor was uninstalled from `treasury`; rules of `epoch` are discarded.
    event TopUpUninstalled(address indexed treasury, uint64 epoch);
    /// @notice A refill rule was set for `agent`.
    event RuleSet(
        address indexed treasury,
        address indexed agent,
        address indexed token,
        uint128 refillTo,
        uint128 whenBelow,
        uint128 maxPerDay
    );
    /// @notice The refill rule for `agent` was removed.
    event RuleRemoved(address indexed treasury, address indexed agent);
    /// @notice `amount` was transferred from `treasury` to `agent`.
    event ToppedUp(address indexed treasury, address indexed agent, uint256 amount);

    error NotInitialized(address treasury);
    error AlreadyInitialized(address treasury);
    error InvalidAgent(address agent);
    error InvalidRule(address token, uint128 refillTo, uint128 whenBelow, uint128 maxPerDay);
    error RuleNotFound(address treasury, address agent);
    error NotBelowThreshold(address agent, uint256 balance, uint256 whenBelow);
    error NothingToTopUp(address treasury, address agent);
    error TopUpAmountMismatch(uint256 expected, uint256 received);

    /// @notice Sets (or replaces) the caller's refill rule for `agent`.
    function setRule(address agent, address token, uint128 refillTo, uint128 whenBelow, uint128 maxPerDay) external;

    /// @notice Removes the caller's refill rule for `agent`.
    function removeRule(address agent) external;

    /// @notice Refills `agent` from `treasury` according to the treasury's rule. Anyone (keepers).
    function topUp(address treasury, address agent) external returns (uint256 amount);

    /// @notice Amount `topUp(treasury, agent)` would transfer now (0 if it would revert).
    function previewTopUp(address treasury, address agent) external view returns (uint256 amount);

    /// @notice `treasury`'s rule for `agent`.
    function getRule(address treasury, address agent) external view returns (TopUpRule memory);

    /// @notice Amount topped up from `treasury` to `agent` in the current UTC day.
    function spentToday(address treasury, address agent) external view returns (uint256);

    /// @notice Whether `treasury` has the executor installed.
    function isInitialized(address treasury) external view returns (bool);
}
