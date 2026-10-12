// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TokenTransfer
/// @notice Inbound transfers that must credit exactly the requested amount.
/// @dev Fee-on-transfer, deflationary and otherwise non-standard tokens are rejected rather than accounted for: every
///      contract in this repository tracks liabilities in requested units, so a short credit would break the
///      `balanceOf(this) >= sum(liabilities)` invariant. Rebasing tokens are unsupported (documented in AUDIT_SCOPE.md).
library TokenTransfer {
    using SafeERC20 for IERC20;

    /// @notice The token credited a different amount than requested.
    error TransferAmountMismatch(address token, uint256 expected, uint256 received);

    /// @notice Attempts to send exactly `amount` of `token` to `to` without reverting if the token refuses.
    /// @dev Balances, not return values, decide the outcome: returns true if exactly `amount` left this contract, false
    ///      if nothing moved (e.g. the recipient is frozen by the token, or the call ran out of gas), and reverts on any
    ///      other balance change. A token that moves funds but reports failure can therefore never cause a double
    ///      payment, and one that reports success without moving funds never marks a debt as paid.
    /// @param token ERC-20 token.
    /// @param to Recipient.
    /// @param amount Exact amount to send.
    /// @return sent Whether `amount` was sent.
    function tryPushExact(address token, address to, uint256 amount) internal returns (bool sent) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        // forge-lint: disable-next-line(unused-return)
        IERC20(token).trySafeTransfer(to, amount); // outcome is read from balances below
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter == balanceBefore) return false;
        if (balanceAfter < balanceBefore && balanceBefore - balanceAfter == amount) return true;
        revert TransferAmountMismatch(token, amount, balanceAfter < balanceBefore ? balanceBefore - balanceAfter : 0);
    }

    /// @notice Pulls exactly `amount` of `token` from the caller (`msg.sender`) into this contract or reverts.
    /// @dev Always pulls from `msg.sender` (internal library code runs in the caller's context), so no call site can
    ///      ever pull from a third party's allowance.
    /// @param token ERC-20 token.
    /// @param amount Exact amount that must arrive.
    function pullExact(address token, uint256 amount) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount) {
            revert TransferAmountMismatch(
                token, amount, balanceAfter < balanceBefore ? 0 : balanceAfter - balanceBefore
            );
        }
    }
}
