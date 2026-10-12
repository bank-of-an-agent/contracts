// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @title MockTreasuryFund
/// @notice TEST/ANVIL ONLY. A synchronous ERC-4626 "tokenized treasury fund" over MockUSDC. Yield is simulated by
///         minting the asset to the fund. The deployer may set a global deposit cap to exercise `maxDeposit` limits.
///         Real treasury funds (BENJI, USDY, BUIDL, …) have KYC gates and asynchronous settlement; this mock has
///         neither.
contract MockTreasuryFund is ERC4626 {
    /// @notice Deployer; may change the deposit cap.
    address public immutable admin;
    /// @notice Maximum total assets the fund accepts (0 = unlimited).
    uint256 public depositCap;

    /// @notice The deposit cap changed.
    event DepositCapSet(uint256 depositCap);

    /// @param asset_ Underlying asset (MockUSDC).
    constructor(IERC20 asset_) ERC20("Mock Treasury Fund", "mTBILL") ERC4626(asset_) {
        admin = msg.sender;
    }

    /// @notice Sets the global deposit cap (0 = unlimited). Admin only.
    /// @param depositCap_ New cap in asset units.
    function setDepositCap(uint256 depositCap_) external {
        require(msg.sender == admin, "MockTreasuryFund: not admin");
        depositCap = depositCap_;
        emit DepositCapSet(depositCap_);
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        uint256 cap = depositCap;
        if (cap == 0) return type(uint256).max;
        uint256 assets = totalAssets();
        return assets >= cap ? 0 : cap - assets;
    }

    /// @inheritdoc ERC4626
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return maxAssets == type(uint256).max ? type(uint256).max : convertToShares(maxAssets);
    }
}
