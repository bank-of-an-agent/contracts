// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Test.sol";

import {AgentPolicyHook} from "../../src/AgentPolicyHook.sol";
import {IAgentPolicyHook} from "../../src/interfaces/IAgentPolicyHook.sol";
import {MODULE_TYPE_HOOK} from "../../src/interfaces/IERC7579.sol";
import {MockERC7579Account} from "../mocks/MockERC7579Account.sol";
import {BaseTest} from "../utils/BaseTest.sol";

/// @title Local companion to the Phase 0 spike: ERC-1271 signatures bypass on-chain spend policy.
/// @notice An agent account runs AgentPolicyHook (25 USDC per tx, 200 USDC per day, recipient allowlist). Its session
///         key cannot move more than the caps through the execution path, but if the account also lets that key sign
///         ERC-1271 messages, an EIP-3009 authorization or an EIP-2612 permit moves the ENTIRE balance without the hook
///         ever running. See docs/spike-x402-erc1271.md §3.2 and ADR 0001 (decision 4: no ERC-1271 for agent keys).
contract Erc1271SpendCapBypassTest is BaseTest {
    AgentPolicyHook internal hook;
    MockERC7579Account internal account;
    Vm.Wallet internal sessionKey;
    address internal principal = makeAddr("principal");
    address internal merchant = makeAddr("merchant");
    address internal attacker = makeAddr("attacker");
    address internal facilitator = makeAddr("facilitator");

    uint256 internal constant BALANCE = 10_000e6;

    function setUp() public override {
        super.setUp();
        hook = new AgentPolicyHook();
        account = new MockERC7579Account(entryPoint, principal);
        sessionKey = vm.createWallet("agent-session-key");
        _fund(address(account), BALANCE);

        IAgentPolicyHook.PolicyConfig memory c;
        c.tokenLimits = new IAgentPolicyHook.TokenLimitConfig[](1);
        c.tokenLimits[0] = IAgentPolicyHook.TokenLimitConfig(address(usdc), 25e6, 200e6);
        c.allowedRecipients = new address[](1);
        c.allowedRecipients[0] = merchant;
        c.recipientAllowlistEnabled = true;
        vm.prank(entryPoint);
        account.installModule(MODULE_TYPE_HOOK, address(hook), abi.encode(c));
    }

    function _grantErc1271(bool allowed) internal {
        vm.prank(principal);
        account.ownerExecute(
            address(account), 0, abi.encodeCall(MockERC7579Account.setErc1271Signer, (sessionKey.addr, allowed))
        );
    }

    function _authorization(address to, uint256 value, bytes32 nonce) internal view returns (bytes memory sig) {
        bytes32 structHash = keccak256(
            abi.encode(
                usdc.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
                address(account),
                to,
                value,
                block.timestamp - 1,
                block.timestamp + 60,
                nonce
            )
        );
        sig = _sign(sessionKey.privateKey, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
    }

    /// @notice Baseline: through the execution path the hook caps the agent.
    function test_executionPath_isCapped() public {
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.RecipientNotAllowed.selector, attacker));
        account.execute(_singleMode(), _single(address(usdc), 0, abi.encodeCall(IERC20.transfer, (attacker, 1e6))));

        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), BALANCE, 25e6)
        );
        account.execute(_singleMode(), _single(address(usdc), 0, abi.encodeCall(IERC20.transfer, (merchant, BALANCE))));
    }

    /// @notice The bypass: with ERC-1271 rights the same key drains the account via EIP-3009, unseen by the hook.
    function test_erc1271_eip3009_bypassesHookCapsAndAllowlist() public {
        _grantErc1271(true);
        bytes memory sig = _authorization(attacker, BALANCE, keccak256("drain"));

        vm.prank(facilitator);
        usdc.transferWithAuthorization(
            address(account), attacker, BALANCE, block.timestamp - 1, block.timestamp + 60, keccak256("drain"), sig
        );

        assertEq(usdc.balanceOf(attacker), BALANCE, "entire balance moved");
        assertEq(usdc.balanceOf(address(account)), 0);
        assertEq(hook.spentToday(address(account), address(usdc)), 0, "the hook never saw it");
    }

    /// @notice Same bypass with an EIP-2612 permit: a persistent unlimited allowance for the attacker.
    function test_erc1271_permit_bypassesHook() public {
        _grantErc1271(true);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(
            abi.encode(
                usdc.PERMIT_TYPEHASH(),
                address(account),
                attacker,
                type(uint256).max,
                usdc.nonces(address(account)),
                deadline
            )
        );
        bytes memory sig =
            _sign(sessionKey.privateKey, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
        usdc.permit(address(account), attacker, type(uint256).max, deadline, sig);

        vm.prank(attacker);
        usdc.transferFrom(address(account), attacker, BALANCE);
        assertEq(usdc.balanceOf(attacker), BALANCE);
        assertEq(hook.spentToday(address(account), address(usdc)), 0);
    }

    /// @notice The mitigation in ADR 0001: agent keys get no ERC-1271 rights, so the bypass disappears.
    function test_withoutErc1271Rights_signaturesAreRejected() public {
        bytes memory sig = _authorization(attacker, BALANCE, keccak256("drain"));
        vm.prank(facilitator);
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        usdc.transferWithAuthorization(
            address(account), attacker, BALANCE, block.timestamp - 1, block.timestamp + 60, keccak256("drain"), sig
        );
        assertEq(usdc.balanceOf(address(account)), BALANCE);
    }
}
