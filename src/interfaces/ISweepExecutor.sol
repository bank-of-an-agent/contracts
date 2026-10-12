// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title ISweepExecutor
/// @notice Types, events, errors and functions of the Agent Bank treasury-sweep ERC-7579 executor.
interface ISweepExecutor {
    /// @notice An account's standing sweep rule (set only by the account itself).
    struct SweepConfig {
        address fund; // ERC-4626 fund the owner selected; the ONLY contract (besides `asset.approve`) ever called
        address asset; // must equal fund.asset()
        uint16 maxSavingsBps; // max share of (liquid + invested) value held in the fund, 0..10_000
        uint256 liquidFloor; // asset balance to keep liquid; redemptions refill up to it
        uint256 sweepThreshold; // minimum excess above the floor before a sweep happens
    }

    /// @notice The account installed or changed its sweep rule.
    event SweepConfigured(
        address indexed account,
        address indexed fund,
        address indexed asset,
        uint256 liquidFloor,
        uint256 sweepThreshold,
        uint16 maxSavingsBps
    );
    /// @notice The account uninstalled the executor.
    event SweepUninstalled(address indexed account);
    /// @notice `assets` were subscribed into the fund for `shares`, held by the account.
    event Swept(address indexed account, address indexed fund, address indexed caller, uint256 assets, uint256 shares);
    /// @notice `shares` were redeemed for `assets`, paid to the account.
    event Redeemed(
        address indexed account, address indexed fund, address indexed caller, uint256 shares, uint256 assets
    );

    error NotInitialized(address account);
    error AlreadyInitialized(address account);
    error InvalidFund(address fund);
    error AssetMismatch(address expected, address actual);
    error InvalidMaxSavingsBps(uint16 maxSavingsBps);
    error NothingToSweep(address account);
    error NothingToRedeem(address account);
    error UnexpectedSharesMinted(uint256 expected, uint256 received);
    error UnexpectedAssetsReceived(uint256 expected, uint256 received);

    /// @notice Replaces the caller's sweep rule.
    function setConfig(SweepConfig calldata config) external;

    /// @notice Subscribes the excess liquid balance of `account` into its fund. Anyone (keepers).
    function sweep(address account) external returns (uint256 assets, uint256 shares);

    /// @notice Redeems fund shares of `account` to refill its liquid floor. Anyone (keepers).
    function redeem(address account) external returns (uint256 shares, uint256 assets);

    /// @notice Assets `sweep(account)` would subscribe now (0 if it would revert).
    function previewSweep(address account) external view returns (uint256 assets);

    /// @notice Shares `redeem(account)` would redeem now (0 if it would revert).
    function previewRedeem(address account) external view returns (uint256 shares);

    /// @notice `account`'s sweep rule.
    function getConfig(address account) external view returns (SweepConfig memory);

    /// @notice Whether `account` has the executor installed.
    function isInitialized(address account) external view returns (bool);
}
