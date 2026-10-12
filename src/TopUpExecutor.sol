// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC7579Execution, IERC7579Module, MODE_SINGLE_DEFAULT, MODULE_TYPE_EXECUTOR} from "./interfaces/IERC7579.sol";
import {ITopUpExecutor} from "./interfaces/ITopUpExecutor.sol";

/// @title TopUpExecutor
/// @author Agent Bank
/// @notice ERC-7579 executor (module type 2) installed by the owner on the org treasury account to keep its agents'
///         accounts funded. For each configured agent account the treasury sets `refillTo`, `whenBelow`, `maxPerDay`
///         and the asset. Anyone (a keeper) may call `topUp(treasury, agent)`: if the agent's balance is below
///         `whenBelow`, the treasury transfers `min(refillTo - balance, maxPerDay - spentToday, treasuryBalance)` to
///         that agent through `executeFromExecutor`.
///         The executor can ONLY make the treasury call `token.transfer(agent, amount)` for a configured (agent,
///         token) pair. Funds therefore only move between the principal's own accounts: a keeper, or Agent Bank, can
///         trigger a refill but never redirect funds or exceed the owner's daily cap.
/// @dev Only the treasury itself configures rules (`onInstall` data, `setRule`, `removeRule`). Daily caps use UTC-day
///      buckets per (treasury, agent). Exposure per agent per day is bounded by `maxPerDay` even if the agent's own
///      spending (within its own caps) drains it repeatedly. Uninstalling bumps the epoch, discarding all rules.
contract TopUpExecutor is ITopUpExecutor, IERC7579Module, ReentrancyGuardTransient {
    struct TreasuryState {
        bool initialized;
        uint64 epoch;
    }

    struct Window {
        uint64 day; // UTC day index: block.timestamp / 1 days
        uint192 spent;
    }

    mapping(address treasury => TreasuryState) private _treasuries;
    mapping(address treasury => mapping(uint64 epoch => mapping(address agent => TopUpRule))) private _rules;
    mapping(address treasury => mapping(uint64 epoch => mapping(address agent => Window))) private _windows;

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-7579 module lifecycle
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Installs the executor for the calling treasury account.
    /// @param data Empty, or `abi.encode(RuleInit[])` with the initial refill rules.
    function onInstall(bytes calldata data) external {
        TreasuryState storage st = _treasuries[msg.sender];
        if (st.initialized) revert AlreadyInitialized(msg.sender);
        st.initialized = true;
        uint64 epoch = st.epoch;
        emit TopUpInstalled(msg.sender, epoch);
        if (data.length != 0) {
            RuleInit[] memory rules = abi.decode(data, (RuleInit[]));
            for (uint256 i; i < rules.length; ++i) {
                TopUpRule memory r = rules[i].rule;
                _setRule(msg.sender, epoch, rules[i].agent, r.token, r.refillTo, r.whenBelow, r.maxPerDay);
            }
        }
    }

    /// @notice Uninstalls the executor for the calling treasury, discarding all its rules. Never reverts.
    function onUninstall(bytes calldata) external {
        TreasuryState storage st = _treasuries[msg.sender];
        if (!st.initialized) return;
        uint64 epoch = st.epoch;
        st.initialized = false;
        st.epoch = epoch + 1;
        emit TopUpUninstalled(msg.sender, epoch);
    }

    /// @notice ERC-7579 module type check: this is an executor (type 2) only.
    /// @param moduleTypeId Module type id.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Configuration (msg.sender == treasury)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Sets (or replaces) the caller's refill rule for `agent`. Today's top-up total carries over.
    /// @param agent Agent account to refill (not the caller, not this contract, not the token).
    /// @param token Asset to send.
    /// @param refillTo Target agent balance (> 0).
    /// @param whenBelow Refill only while the agent balance is below this (0 < whenBelow <= refillTo).
    /// @param maxPerDay Max top-ups to this agent per UTC day (> 0).
    function setRule(address agent, address token, uint128 refillTo, uint128 whenBelow, uint128 maxPerDay) external {
        _setRule(msg.sender, _requireInitialized(msg.sender), agent, token, refillTo, whenBelow, maxPerDay);
    }

    /// @notice Removes the caller's refill rule for `agent`.
    /// @param agent Agent account.
    function removeRule(address agent) external {
        uint64 epoch = _requireInitialized(msg.sender);
        if (_rules[msg.sender][epoch][agent].token == address(0)) revert RuleNotFound(msg.sender, agent);
        delete _rules[msg.sender][epoch][agent];
        emit RuleRemoved(msg.sender, agent);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Keeper action
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Refills `agent` from `treasury` per the treasury's rule. Callable by anyone.
    /// @param treasury Treasury account that installed this executor.
    /// @param agent Configured agent account.
    /// @return amount Amount transferred.
    function topUp(address treasury, address agent) external nonReentrant returns (uint256 amount) {
        TreasuryState memory st = _treasuries[treasury];
        if (!st.initialized) revert NotInitialized(treasury);
        TopUpRule memory r = _rules[treasury][st.epoch][agent];
        if (r.token == address(0)) revert RuleNotFound(treasury, agent);

        uint256 balance = IERC20(r.token).balanceOf(agent);
        if (balance >= r.whenBelow) revert NotBelowThreshold(agent, balance, r.whenBelow);

        Window storage window = _windows[treasury][st.epoch][agent];
        uint64 today = _today();
        uint256 spent = window.day == today ? window.spent : 0;
        amount = _topUpAmount(treasury, r, balance, spent);
        if (amount == 0) revert NothingToTopUp(treasury, agent);

        window.day = today;
        // forge-lint: disable-next-line(unsafe-typecast)
        window.spent = uint192(spent + amount); // <= maxPerDay <= uint128 max
        // Only view calls (balanceOf) precede this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ToppedUp(treasury, agent, amount);

        // Return data is not trusted; the effect is verified through the agent's balance below.
        // forge-lint: disable-start(unused-return)
        IERC7579Execution(treasury)
            .executeFromExecutor(
                MODE_SINGLE_DEFAULT,
                abi.encodePacked(r.token, uint256(0), abi.encodeCall(IERC20.transfer, (agent, amount)))
            );
        // forge-lint: disable-end(unused-return)
        uint256 balanceAfter = IERC20(r.token).balanceOf(agent);
        uint256 received = balanceAfter > balance ? balanceAfter - balance : 0;
        if (received != amount) revert TopUpAmountMismatch(amount, received);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ITopUpExecutor
    function previewTopUp(address treasury, address agent) external view returns (uint256 amount) {
        TreasuryState memory st = _treasuries[treasury];
        if (!st.initialized) return 0;
        TopUpRule memory r = _rules[treasury][st.epoch][agent];
        if (r.token == address(0)) return 0;
        uint256 balance = IERC20(r.token).balanceOf(agent);
        if (balance >= r.whenBelow) return 0;
        return _topUpAmount(treasury, r, balance, spentToday(treasury, agent));
    }

    /// @inheritdoc ITopUpExecutor
    function getRule(address treasury, address agent) external view returns (TopUpRule memory) {
        return _rules[treasury][_treasuries[treasury].epoch][agent];
    }

    /// @inheritdoc ITopUpExecutor
    function spentToday(address treasury, address agent) public view returns (uint256) {
        Window memory window = _windows[treasury][_treasuries[treasury].epoch][agent];
        return window.day == _today() ? window.spent : 0;
    }

    /// @inheritdoc ITopUpExecutor
    function isInitialized(address treasury) external view returns (bool) {
        return _treasuries[treasury].initialized;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `min(refillTo - balance, maxPerDay - spentToday, treasuryBalance)`; requires balance < whenBelow <= refillTo.
    function _topUpAmount(address treasury, TopUpRule memory r, uint256 balance, uint256 spent)
        private
        view
        returns (uint256)
    {
        uint256 remainingToday = spent >= r.maxPerDay ? 0 : r.maxPerDay - spent;
        uint256 need = r.refillTo - balance;
        return Math.min(Math.min(need, remainingToday), IERC20(r.token).balanceOf(treasury));
    }

    function _requireInitialized(address treasury) private view returns (uint64) {
        TreasuryState memory st = _treasuries[treasury];
        if (!st.initialized) revert NotInitialized(treasury);
        return st.epoch;
    }

    function _setRule(
        address treasury,
        uint64 epoch,
        address agent,
        address token,
        uint128 refillTo,
        uint128 whenBelow,
        uint128 maxPerDay
    ) private {
        if (agent == address(0) || agent == treasury || agent == address(this) || agent == token) {
            revert InvalidAgent(agent);
        }
        if (
            token == address(0) || token == treasury || refillTo == 0 || whenBelow == 0 || whenBelow > refillTo
                || maxPerDay == 0
        ) {
            revert InvalidRule(token, refillTo, whenBelow, maxPerDay);
        }
        _rules[treasury][epoch][agent] = TopUpRule(token, refillTo, whenBelow, maxPerDay);
        emit RuleSet(treasury, agent, token, refillTo, whenBelow, maxPerDay);
    }

    function _today() private view returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.timestamp / 1 days);
    }
}
