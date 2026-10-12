// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice ERC-4626 whose `deposit` mints half of what `previewDeposit` promised.
contract ShortMintFund is ERC4626 {
    constructor(IERC20 asset_) ERC20("Short Mint Fund", "SHORT") ERC4626(asset_) {}

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares / 2);
    }
}

/// @notice ERC-4626 whose `redeem` pays out half of what `previewRedeem` promised (keeps the rest).
contract ShortRedeemFund is ERC4626 {
    constructor(IERC20 asset_) ERC20("Short Redeem Fund", "SHORTR") ERC4626(asset_) {}

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        super._withdraw(caller, receiver, owner, assets / 2, shares);
    }
}

/// @notice A contract that is not ERC-4626 at all but reports some asset.
contract FakeFund {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }
}
