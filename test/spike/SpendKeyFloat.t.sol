// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Test.sol";

import {AgentPolicyHook} from "../../src/AgentPolicyHook.sol";
import {IAgentPolicyHook} from "../../src/interfaces/IAgentPolicyHook.sol";
import {MODULE_TYPE_HOOK} from "../../src/interfaces/IERC7579.sol";
import {MockERC7579Account} from "../mocks/MockERC7579Account.sol";
import {BaseTest} from "../utils/BaseTest.sol";

/// @title ADR 0001 end to end: per-agent spend key with a small float, refilled under policy.
/// @notice The agent's smart account (AgentPolicyHook: refills capped at 25 USDC per tx and 100 USDC per day, only to
///         the spend key) funds an EOA spend key that signs standard EIP-3009 x402 payments. Shows: standard x402
///         settlement works; daily x402 spend is bounded by the on-chain refill cap; a leaked spend key loses at most
///         its float and cannot touch the account; the float is recoverable without the agent via a permit allowance.
contract SpendKeyFloatTest is BaseTest {
    AgentPolicyHook internal hook;
    MockERC7579Account internal account;
    Vm.Wallet internal spendKey;
    address internal principal = makeAddr("principal");
    address internal seller = makeAddr("x402-seller");
    address internal facilitator = makeAddr("x402-facilitator");
    address internal attacker = makeAddr("attacker");

    uint128 internal constant FLOAT = 25e6;
    uint128 internal constant REFILLS_PER_DAY = 100e6;
    uint256 internal nonceCounter;

    function setUp() public override {
        super.setUp();
        hook = new AgentPolicyHook();
        account = new MockERC7579Account(entryPoint, principal);
        spendKey = vm.createWallet("agent-spend-key");
        _fund(address(account), 10_000e6);

        IAgentPolicyHook.PolicyConfig memory c;
        c.tokenLimits = new IAgentPolicyHook.TokenLimitConfig[](1);
        c.tokenLimits[0] = IAgentPolicyHook.TokenLimitConfig(address(usdc), FLOAT, REFILLS_PER_DAY);
        c.allowedRecipients = new address[](1);
        c.allowedRecipients[0] = spendKey.addr;
        c.recipientAllowlistEnabled = true;
        vm.prank(entryPoint);
        account.installModule(MODULE_TYPE_HOOK, address(hook), abi.encode(c));

        // Provisioning: the spend key grants its parent account an allowance (gasless EIP-2612, relayed by anyone).
        uint256 deadline = block.timestamp + 365 days;
        bytes32 structHash = keccak256(
            abi.encode(usdc.PERMIT_TYPEHASH(), spendKey.addr, address(account), type(uint256).max, 0, deadline)
        );
        usdc.permit(
            spendKey.addr,
            address(account),
            type(uint256).max,
            deadline,
            _sign(spendKey.privateKey, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)))
        );
    }

    // ------------------------------------------------------------------ helpers

    function _refill(uint256 amount) internal {
        vm.prank(entryPoint); // session key + co-signer user operation
        account.execute(
            _singleMode(), _single(address(usdc), 0, abi.encodeCall(IERC20.transfer, (spendKey.addr, amount)))
        );
    }

    function _x402Pay(uint256 signerPk, address from, address to, uint256 value) internal returns (bool ok) {
        bytes32 nonce = keccak256(abi.encode("x402", ++nonceCounter));
        bytes32 structHash = keccak256(
            abi.encode(
                usdc.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
                from,
                to,
                value,
                block.timestamp - 1,
                block.timestamp + 60,
                nonce
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerPk, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
        vm.prank(facilitator);
        try usdc.transferWithAuthorization(from, to, value, block.timestamp - 1, block.timestamp + 60, nonce, v, r, s) {
            ok = true;
        } catch {}
    }

    // ------------------------------------------------------------------ tests

    function test_standardX402PaymentFromSpendKey() public {
        _refill(FLOAT);
        assertTrue(_x402Pay(spendKey.privateKey, spendKey.addr, seller, 1_250_000));
        assertEq(usdc.balanceOf(seller), 1_250_000);
        assertEq(usdc.balanceOf(spendKey.addr), FLOAT - 1_250_000);
    }

    function test_refillsAreCappedOnChain_soDailyX402SpendIsBounded() public {
        uint256 paid;
        for (uint256 i; i < 4; ++i) {
            _refill(FLOAT);
            assertTrue(_x402Pay(spendKey.privateKey, spendKey.addr, seller, FLOAT));
            paid += FLOAT;
        }
        // the fifth refill of the day exceeds the on-chain cap, whatever the co-signer says
        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentPolicyHook.DailyLimitExceeded.selector, address(usdc), REFILLS_PER_DAY + FLOAT, REFILLS_PER_DAY
            )
        );
        account.execute(
            _singleMode(), _single(address(usdc), 0, abi.encodeCall(IERC20.transfer, (spendKey.addr, FLOAT)))
        );
        assertFalse(_x402Pay(spendKey.privateKey, spendKey.addr, seller, 1));
        assertEq(paid, REFILLS_PER_DAY);

        _nextUtcDay();
        _refill(FLOAT);
        assertTrue(_x402Pay(spendKey.privateKey, spendKey.addr, seller, FLOAT));
    }

    function test_refillsOnlyToTheSpendKey() public {
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.RecipientNotAllowed.selector, attacker));
        account.execute(_singleMode(), _single(address(usdc), 0, abi.encodeCall(IERC20.transfer, (attacker, 1))));
    }

    /// @notice A leaked spend key loses at most its float: it cannot sign for the account or pull from it.
    function test_leakedSpendKey_lossBoundedByFloat() public {
        _refill(FLOAT);
        uint256 accountBalance = usdc.balanceOf(address(account));

        assertTrue(_x402Pay(spendKey.privateKey, spendKey.addr, attacker, FLOAT), "float is lost");
        assertFalse(_x402Pay(spendKey.privateKey, spendKey.addr, attacker, 1), "nothing more");
        assertFalse(_x402Pay(spendKey.privateKey, address(account), attacker, 1), "cannot sign for the account");
        assertEq(usdc.allowance(address(account), spendKey.addr), 0, "no allowance from the account");
        assertEq(usdc.balanceOf(attacker), FLOAT);
        assertEq(usdc.balanceOf(address(account)), accountBalance);
    }

    /// @notice The float is recoverable without the agent runtime: the owner sweeps it back with the permit allowance.
    function test_floatRecoverableByOwnerWithoutAgent() public {
        _refill(FLOAT);
        uint256 float = usdc.balanceOf(spendKey.addr);
        vm.prank(principal); // the owner's native path (exit tool)
        account.ownerExecute(
            address(usdc), 0, abi.encodeCall(IERC20.transferFrom, (spendKey.addr, address(account), float))
        );
        assertEq(usdc.balanceOf(spendKey.addr), 0);

        // the agent path may sweep it back too: a pull into the account is an inflow for the hook
        _refill(FLOAT);
        vm.prank(entryPoint);
        account.execute(
            _singleMode(),
            _single(address(usdc), 0, abi.encodeCall(IERC20.transferFrom, (spendKey.addr, address(account), FLOAT)))
        );
        assertEq(usdc.balanceOf(spendKey.addr), 0);
    }
}
