// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain 18-decimal ERC-20 with an open faucet.
contract TestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Burns 1% of every transfer (fee-on-transfer); must be rejected by exact-amount pulls.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice Returns false instead of reverting on failed transfers.
contract FalseReturnToken is ERC20 {
    bool public failTransfers;

    constructor() ERC20("False Token", "FALSE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfers(bool fail) external {
        failTransfers = fail;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (failTransfers) return false;
        return super.transferFrom(from, to, value);
    }
}

/// @notice Calls an arbitrary target after every balance update (ERC-777-style hook) to test reentrancy guards.
///         The callback's revert bubbles up so tests can assert the exact guard error.
contract CallbackToken is ERC20 {
    address public callbackTarget;
    bytes public callbackData;
    bool private _inCallback;

    constructor() ERC20("Callback Token", "CBK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        address target = callbackTarget;
        if (target != address(0) && !_inCallback && from != address(0)) {
            _inCallback = true;
            (bool ok, bytes memory ret) = target.call(callbackData);
            _inCallback = false;
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

/// @notice Pathological token: `transferFrom(from, to, v)` moves `v` from `to` back to `from`, so the receiver's
///         balance shrinks. Exact-amount pulls must reject it.
contract ReverseTransferToken is ERC20 {
    constructor() ERC20("Reverse Token", "REV") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _transfer(to, from, value);
        return true;
    }
}

/// @notice Misbehaves only on `transfer`s to `target`, in one of several ways, to exercise balance-checked payouts.
contract WeirdTransferToken is ERC20 {
    enum Mode {
        Normal,
        MovesButReturnsFalse,
        ReturnsTrueWithoutMoving,
        DebitsTwice,
        CreditsSender
    }

    Mode public mode;
    address public target;

    constructor() ERC20("Weird Token", "WEIRD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMisbehaviour(address target_, Mode mode_) external {
        target = target_;
        mode = mode_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (to != target || mode == Mode.Normal) return super.transfer(to, value);
        if (mode == Mode.MovesButReturnsFalse) {
            super.transfer(to, value);
            return false;
        }
        if (mode == Mode.ReturnsTrueWithoutMoving) return true;
        if (mode == Mode.CreditsSender) {
            _mint(msg.sender, value); // the sender's balance goes *up*
            return true;
        }
        _transfer(msg.sender, to, value);
        _transfer(msg.sender, address(0xdead), value); // DebitsTwice
        return true;
    }
}
