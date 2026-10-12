// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    Execution,
    IERC7579Execution,
    IERC7579Module,
    MODE_BATCH_DEFAULT,
    MODE_SINGLE_DEFAULT,
    MODULE_TYPE_EXECUTOR
} from "./interfaces/IERC7579.sol";
import {ISweepExecutor} from "./interfaces/ISweepExecutor.sol";

/// @title SweepExecutor
/// @author Agent Bank
/// @notice ERC-7579 executor (module type 2) for an owner's treasury account. The owner installs it with a standing
///         rule: an ERC-4626 fund they selected, a liquid floor, a sweep threshold and a cap on the share of funds in
///         savings. Anyone (a keeper) may then:
///         - `sweep`: when the liquid balance exceeds the floor by at least the threshold, subscribe the excess above
///           the floor (capped by `maxSavingsBps` of total value and by the fund's `maxDeposit`);
///         - `redeem`: when the liquid balance is below the floor, redeem shares to refill it (capped by `maxRedeem`).
///         The executor can ONLY call `asset.approve(fund, …)` and `fund.deposit/redeem` with the account as receiver
///         and owner: shares and redemptions always go to the account itself. Keepers (including Agent Bank) can
///         trigger the owner's rule but can never redirect funds.
/// @dev Only the account itself configures its rule (`onInstall` data or `setConfig`). The fund must price shares
///      from a NAV that cannot be moved within a transaction (e.g. a regulated tokenized treasury fund): `sweep` and
///      `redeem` are permissionless, so a fund whose price can be manipulated in-block could be sandwiched.
///      If the account also runs AgentPolicyHook, the fund must be allowlisted there and sweeps count against the
///      asset's caps.
contract SweepExecutor is ISweepExecutor, IERC7579Module, ReentrancyGuardTransient {
    /// @notice Basis-point denominator for `maxSavingsBps`.
    uint16 public constant BPS = 10_000;
    /// @notice Most value a subscription may lose to share-price rounding (0.1%). Guards permissionless sweeps against
    ///         ERC-4626 donation/inflation setups (e.g. a near-empty fund with an inflated share price), where the
    ///         shares minted would be worth materially less than the assets paid.
    uint16 public constant MAX_SUBSCRIPTION_LOSS_BPS = 10;

    mapping(address account => SweepConfig) private _configs;

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-7579 module lifecycle
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Installs the executor for the calling account.
    /// @param data `abi.encode(SweepConfig)` (required).
    function onInstall(bytes calldata data) external {
        if (_configs[msg.sender].fund != address(0)) revert AlreadyInitialized(msg.sender);
        _setConfig(msg.sender, abi.decode(data, (SweepConfig)));
    }

    /// @notice Uninstalls the executor for the calling account, deleting its rule. Never reverts.
    function onUninstall(bytes calldata) external {
        if (_configs[msg.sender].fund == address(0)) return;
        delete _configs[msg.sender];
        emit SweepUninstalled(msg.sender);
    }

    /// @notice ERC-7579 module type check: this is an executor (type 2) only.
    /// @param moduleTypeId Module type id.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Configuration (msg.sender == account)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Replaces the caller's sweep rule. Changing the fund leaves shares of the old fund in the account
    ///         (redeem them through the owner's path).
    /// @param config New rule.
    function setConfig(SweepConfig calldata config) external {
        if (_configs[msg.sender].fund == address(0)) revert NotInitialized(msg.sender);
        _setConfig(msg.sender, config);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Keeper actions
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Subscribes `account`'s excess liquid asset into its fund, through the account.
    /// @param account Smart account that installed this executor.
    /// @return assets Assets subscribed.
    /// @return shares Fund shares minted to the account.
    function sweep(address account) external nonReentrant returns (uint256 assets, uint256 shares) {
        SweepConfig memory c = _requireConfig(account);
        IERC4626 fund = IERC4626(c.fund);
        assets = _sweepAmount(account, c);
        if (assets == 0) revert NothingToSweep(account);
        uint256 expectedShares = fund.previewDeposit(assets);
        if (expectedShares == 0) revert NothingToSweep(account); // dust that would mint nothing

        uint256 sharesBefore = fund.balanceOf(account);
        Execution[] memory executions = new Execution[](3);
        executions[0] = Execution(c.asset, 0, abi.encodeCall(IERC20.approve, (c.fund, assets)));
        executions[1] = Execution(c.fund, 0, abi.encodeCall(IERC4626.deposit, (assets, account)));
        executions[2] = Execution(c.asset, 0, abi.encodeCall(IERC20.approve, (c.fund, 0)));
        // Return data is not trusted; the effect is verified through the share balance below.
        // forge-lint: disable-next-line(unused-return)
        IERC7579Execution(account).executeFromExecutor(MODE_BATCH_DEFAULT, abi.encode(executions));

        uint256 sharesAfter = fund.balanceOf(account);
        shares = sharesAfter > sharesBefore ? sharesAfter - sharesBefore : 0;
        if (shares < expectedShares) revert UnexpectedSharesMinted(expectedShares, shares);
        uint256 sharesValue = fund.convertToAssets(shares);
        if (sharesValue * BPS < assets * (BPS - MAX_SUBSCRIPTION_LOSS_BPS)) {
            revert SubscriptionLossTooHigh(assets, sharesValue);
        }
        // Reports the measured result, so it must follow the execution; reentry is blocked by nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Swept(account, c.fund, msg.sender, assets, shares);
    }

    /// @notice Redeems `account`'s fund shares to refill its liquid floor, through the account.
    /// @param account Smart account that installed this executor.
    /// @return shares Shares redeemed.
    /// @return assets Assets received by the account.
    function redeem(address account) external nonReentrant returns (uint256 shares, uint256 assets) {
        SweepConfig memory c = _requireConfig(account);
        IERC4626 fund = IERC4626(c.fund);
        shares = _redeemShares(account, c);
        if (shares == 0) revert NothingToRedeem(account);
        uint256 expectedAssets = fund.previewRedeem(shares);
        if (expectedAssets == 0) revert NothingToRedeem(account);

        uint256 assetsBefore = IERC20(c.asset).balanceOf(account);
        // Return data is not trusted; the effect is verified through the asset balance below.
        // forge-lint: disable-start(unused-return)
        IERC7579Execution(account)
            .executeFromExecutor(
                MODE_SINGLE_DEFAULT,
                abi.encodePacked(c.fund, uint256(0), abi.encodeCall(IERC4626.redeem, (shares, account, account)))
            );
        // forge-lint: disable-end(unused-return)

        uint256 assetsAfter = IERC20(c.asset).balanceOf(account);
        assets = assetsAfter > assetsBefore ? assetsAfter - assetsBefore : 0;
        if (assets < expectedAssets) revert UnexpectedAssetsReceived(expectedAssets, assets);
        // Reports the measured result, so it must follow the execution; reentry is blocked by nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(account, c.fund, msg.sender, shares, assets);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISweepExecutor
    function previewSweep(address account) external view returns (uint256 assets) {
        SweepConfig memory c = _configs[account];
        if (c.fund == address(0)) return 0;
        assets = _sweepAmount(account, c);
        if (assets != 0 && IERC4626(c.fund).previewDeposit(assets) == 0) return 0;
    }

    /// @inheritdoc ISweepExecutor
    function previewRedeem(address account) external view returns (uint256 shares) {
        SweepConfig memory c = _configs[account];
        if (c.fund == address(0)) return 0;
        shares = _redeemShares(account, c);
        if (shares != 0 && IERC4626(c.fund).previewRedeem(shares) == 0) return 0;
    }

    /// @inheritdoc ISweepExecutor
    function getConfig(address account) external view returns (SweepConfig memory) {
        return _configs[account];
    }

    /// @inheritdoc ISweepExecutor
    function isInitialized(address account) external view returns (bool) {
        return _configs[account].fund != address(0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    function _requireConfig(address account) private view returns (SweepConfig memory c) {
        c = _configs[account];
        if (c.fund == address(0)) revert NotInitialized(account);
    }

    function _setConfig(address account, SweepConfig memory c) private {
        if (c.fund == address(0) || c.fund == account || c.fund == address(this) || c.fund.code.length == 0) {
            revert InvalidFund(c.fund);
        }
        address fundAsset = IERC4626(c.fund).asset();
        if (c.asset != fundAsset || c.asset == account) revert AssetMismatch(fundAsset, c.asset);
        if (c.maxSavingsBps > BPS) revert InvalidMaxSavingsBps(c.maxSavingsBps);
        _configs[account] = c;
        emit SweepConfigured(account, c.fund, c.asset, c.liquidFloor, c.sweepThreshold, c.maxSavingsBps);
    }

    /// @dev Excess above the floor (only once it reaches the threshold), capped so that invested value stays within
    ///      `maxSavingsBps` of total value, and by the fund's `maxDeposit`.
    function _sweepAmount(address account, SweepConfig memory c) private view returns (uint256) {
        uint256 liquid = IERC20(c.asset).balanceOf(account);
        if (liquid <= c.liquidFloor) return 0;
        uint256 excess = liquid - c.liquidFloor;
        if (excess < c.sweepThreshold) return 0;

        IERC4626 fund = IERC4626(c.fund);
        uint256 invested = fund.convertToAssets(fund.balanceOf(account));
        uint256 maxInvested = Math.mulDiv(liquid + invested, c.maxSavingsBps, BPS);
        if (maxInvested <= invested) return 0;
        return Math.min(Math.min(excess, maxInvested - invested), fund.maxDeposit(account));
    }

    /// @dev Shares needed to restore the floor (rounded up by the fund), capped by the fund's `maxRedeem`.
    function _redeemShares(address account, SweepConfig memory c) private view returns (uint256) {
        uint256 liquid = IERC20(c.asset).balanceOf(account);
        if (liquid >= c.liquidFloor) return 0;
        IERC4626 fund = IERC4626(c.fund);
        return Math.min(fund.previewWithdraw(c.liquidFloor - liquid), fund.maxRedeem(account));
    }
}
