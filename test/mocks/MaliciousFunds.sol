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

/// @notice ERC-4626 that calls back into an arbitrary target during deposits/withdrawals (reentrancy probe).
contract ReentrantFund is ERC4626 {
    address public target;
    bytes public data;

    constructor(IERC20 asset_) ERC20("Reentrant Fund", "REENT") ERC4626(asset_) {}

    function setCallback(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _callback();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _callback();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _callback() private {
        if (target == address(0)) return;
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @notice ERC-4626 that takes the assets but mints no shares.
contract ZeroMintFund is ERC4626 {
    constructor(IERC20 asset_) ERC20("Zero Mint Fund", "ZERO") ERC4626(asset_) {}

    function _deposit(address caller, address receiver, uint256 assets, uint256) internal override {
        super._deposit(caller, receiver, assets, 0);
    }
}

/// @notice ERC-4626 that burns shares on redeem but pays nothing.
contract NoPayFund is ERC4626 {
    constructor(IERC20 asset_) ERC20("No Pay Fund", "NOPAY") ERC4626(asset_) {}

    function _withdraw(address caller, address receiver, address owner, uint256, uint256 shares) internal override {
        super._withdraw(caller, receiver, owner, 0, shares);
    }
}

/// @notice ERC-4626 whose assets can be wiped out (simulates a fund loss that makes shares worthless).
contract LossyFund is ERC4626 {
    constructor(IERC20 asset_) ERC20("Lossy Fund", "LOSS") ERC4626(asset_) {}

    function loseEverything() external {
        IERC20 token = IERC20(asset());
        token.transfer(address(0xdead), token.balanceOf(address(this)));
    }
}
