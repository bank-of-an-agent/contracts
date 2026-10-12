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

    /// @notice Pulls exactly `amount` of `token` from `from` into this contract or reverts.
    /// @param token ERC-20 token.
    /// @param from Address the tokens are pulled from (must have approved this contract).
    /// @param amount Exact amount that must arrive.
    function pullExact(address token, address from, uint256 amount) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount) {
            revert TransferAmountMismatch(
                token, amount, balanceAfter < balanceBefore ? 0 : balanceAfter - balanceBefore
            );
        }
    }
}
