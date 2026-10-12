// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {AgentPolicyHook} from "../../src/AgentPolicyHook.sol";
import {TopUpExecutor} from "../../src/TopUpExecutor.sol";
import {IAgentPolicyHook} from "../../src/interfaces/IAgentPolicyHook.sol";
import {MODULE_TYPE_EXECUTOR, MODULE_TYPE_HOOK} from "../../src/interfaces/IERC7579.sol";
import {ITopUpExecutor} from "../../src/interfaces/ITopUpExecutor.sol";
import {MockERC7579Account} from "../mocks/MockERC7579Account.sol";
import {CallbackToken, FalseReturnToken, FeeOnTransferToken} from "../mocks/TestTokens.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract TopUpExecutorTest is BaseTest {
    TopUpExecutor internal topUps;
    MockERC7579Account internal treasury;
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent-account");
    address internal agent2 = makeAddr("agent-account-2");

    uint128 internal constant REFILL_TO = 100e6;
    uint128 internal constant WHEN_BELOW = 20e6;
    uint128 internal constant MAX_PER_DAY = 250e6;

    function setUp() public override {
        super.setUp();
        topUps = new TopUpExecutor();
        treasury = new MockERC7579Account(entryPoint, principal);
        _fund(address(treasury), 10_000e6);
        ITopUpExecutor.RuleInit[] memory rules = new ITopUpExecutor.RuleInit[](1);
        rules[0] =
            ITopUpExecutor.RuleInit(agent, ITopUpExecutor.TopUpRule(address(usdc), REFILL_TO, WHEN_BELOW, MAX_PER_DAY));
        vm.prank(entryPoint);
        treasury.installModule(MODULE_TYPE_EXECUTOR, address(topUps), abi.encode(rules));
    }

    // ------------------------------------------------------------------ helpers

    function _agentSpends(address who, uint256 amount) internal {
        vm.prank(who);
        usdc.transfer(stranger, amount);
    }

    function _ownerCall(bytes memory data) internal {
        vm.prank(principal);
        treasury.ownerExecute(address(topUps), 0, data);
    }

    // ------------------------------------------------------------------ lifecycle / config

    function test_install_withRules() public view {
        assertTrue(topUps.isInitialized(address(treasury)));
        assertTrue(topUps.isModuleType(MODULE_TYPE_EXECUTOR));
        assertFalse(topUps.isModuleType(MODULE_TYPE_HOOK));
        ITopUpExecutor.TopUpRule memory r = topUps.getRule(address(treasury), agent);
        assertEq(r.token, address(usdc));
        assertEq(r.refillTo, REFILL_TO);
        assertEq(r.whenBelow, WHEN_BELOW);
        assertEq(r.maxPerDay, MAX_PER_DAY);
    }

    function test_install_emptyAndTwice() public {
        MockERC7579Account other = new MockERC7579Account(entryPoint, principal);
        vm.expectEmit(true, false, false, true, address(topUps));
        emit ITopUpExecutor.TopUpInstalled(address(other), 0);
        vm.prank(entryPoint);
        other.installModule(MODULE_TYPE_EXECUTOR, address(topUps), "");
        assertTrue(topUps.isInitialized(address(other)));
        assertEq(topUps.getRule(address(other), agent).token, address(0));

        vm.prank(address(other));
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.AlreadyInitialized.selector, address(other)));
        topUps.onInstall("");
    }

    function test_setRule_validation() public {
        vm.startPrank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.InvalidAgent.selector, address(0)));
        topUps.setRule(address(0), address(usdc), 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.InvalidAgent.selector, address(treasury)));
        topUps.setRule(address(treasury), address(usdc), 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.InvalidAgent.selector, address(topUps)));
        topUps.setRule(address(topUps), address(usdc), 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.InvalidAgent.selector, address(usdc)));
        topUps.setRule(address(usdc), address(usdc), 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.InvalidRule.selector, address(0), 1, 1, 1));
        topUps.setRule(agent2, address(0), 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.InvalidRule.selector, address(treasury), 1, 1, 1));
        topUps.setRule(agent2, address(treasury), 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.InvalidRule.selector, address(usdc), 0, 0, 1));
        topUps.setRule(agent2, address(usdc), 0, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.InvalidRule.selector, address(usdc), 5, 0, 1));
        topUps.setRule(agent2, address(usdc), 5, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.InvalidRule.selector, address(usdc), 5, 6, 1));
        topUps.setRule(agent2, address(usdc), 5, 6, 1);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.InvalidRule.selector, address(usdc), 5, 5, 0));
        topUps.setRule(agent2, address(usdc), 5, 5, 0);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.NotInitialized.selector, stranger));
        topUps.setRule(agent2, address(usdc), 5, 5, 5);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.NotInitialized.selector, stranger));
        topUps.removeRule(agent2);
    }

    function test_setAndRemoveRule_byTreasury() public {
        vm.expectEmit(true, true, true, true, address(topUps));
        emit ITopUpExecutor.RuleSet(address(treasury), agent2, address(usdc), 50e6, 50e6, 60e6);
        _ownerCall(abi.encodeCall(TopUpExecutor.setRule, (agent2, address(usdc), 50e6, 50e6, 60e6)));
        assertEq(topUps.getRule(address(treasury), agent2).maxPerDay, 60e6);

        vm.expectEmit(true, true, false, false, address(topUps));
        emit ITopUpExecutor.RuleRemoved(address(treasury), agent2);
        _ownerCall(abi.encodeCall(TopUpExecutor.removeRule, (agent2)));
        assertEq(topUps.getRule(address(treasury), agent2).token, address(0));

        vm.prank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.RuleNotFound.selector, address(treasury), agent2));
        topUps.removeRule(agent2);
    }

    function test_uninstall_discardsRules() public {
        vm.prank(entryPoint);
        treasury.uninstallModule(MODULE_TYPE_EXECUTOR, address(topUps), "");
        assertFalse(topUps.isInitialized(address(treasury)));
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.NotInitialized.selector, address(treasury)));
        topUps.topUp(address(treasury), agent);
        vm.prank(stranger);
        topUps.onUninstall(""); // never reverts

        vm.prank(entryPoint);
        treasury.installModule(MODULE_TYPE_EXECUTOR, address(topUps), "");
        assertEq(topUps.getRule(address(treasury), agent).token, address(0));
    }

    // ------------------------------------------------------------------ top-ups

    function test_topUp_refillsToTarget_anyoneCanTrigger() public {
        _fund(agent, 5e6);
        assertEq(topUps.previewTopUp(address(treasury), agent), 95e6);
        vm.expectEmit(true, true, false, true, address(topUps));
        emit ITopUpExecutor.ToppedUp(address(treasury), agent, 95e6);
        vm.prank(keeper);
        assertEq(topUps.topUp(address(treasury), agent), 95e6);
        assertEq(usdc.balanceOf(agent), REFILL_TO);
        assertEq(usdc.balanceOf(address(treasury)), 10_000e6 - 95e6);
        assertEq(usdc.balanceOf(keeper), 0);
        assertEq(topUps.spentToday(address(treasury), agent), 95e6);
    }

    function test_topUp_onlyBelowThreshold() public {
        _fund(agent, WHEN_BELOW);
        assertEq(topUps.previewTopUp(address(treasury), agent), 0);
        vm.expectRevert(
            abi.encodeWithSelector(ITopUpExecutor.NotBelowThreshold.selector, agent, WHEN_BELOW, WHEN_BELOW)
        );
        topUps.topUp(address(treasury), agent);
        _agentSpends(agent, 1);
        assertEq(topUps.topUp(address(treasury), agent), REFILL_TO - WHEN_BELOW + 1);
    }

    function test_topUp_dailyCap_andUtcRollover() public {
        assertEq(topUps.topUp(address(treasury), agent), 100e6); // spent 100
        _agentSpends(agent, 100e6);
        assertEq(topUps.topUp(address(treasury), agent), 100e6); // spent 200
        _agentSpends(agent, 100e6);
        assertEq(topUps.topUp(address(treasury), agent), 50e6, "only what is left of the daily cap"); // spent 250
        _agentSpends(agent, 50e6);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.NothingToTopUp.selector, address(treasury), agent));
        topUps.topUp(address(treasury), agent);
        assertEq(topUps.previewTopUp(address(treasury), agent), 0);

        _nextUtcDay();
        assertEq(topUps.spentToday(address(treasury), agent), 0);
        assertEq(topUps.topUp(address(treasury), agent), 100e6);
    }

    function test_topUp_limitedByTreasuryBalance() public {
        vm.prank(principal);
        treasury.ownerExecute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (principal, 10_000e6 - 30e6)));
        assertEq(topUps.topUp(address(treasury), agent), 30e6);
        _agentSpends(agent, 30e6);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.NothingToTopUp.selector, address(treasury), agent));
        topUps.topUp(address(treasury), agent);
    }

    function test_topUp_onlyConfiguredAgents() public {
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.RuleNotFound.selector, address(treasury), agent2));
        topUps.topUp(address(treasury), agent2);
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.NotInitialized.selector, stranger));
        topUps.topUp(stranger, agent);
    }

    function test_replacingRule_keepsTodaysTotal() public {
        topUps.topUp(address(treasury), agent); // 100 today
        _agentSpends(agent, 100e6);
        _ownerCall(abi.encodeCall(TopUpExecutor.setRule, (agent, address(usdc), REFILL_TO, WHEN_BELOW, 120e6)));
        assertEq(topUps.topUp(address(treasury), agent), 20e6, "cap lowered mid-day applies to today's total");
    }

    function test_topUp_requiresExecutorInstalledOnAccount() public {
        MockERC7579Account rogue = new MockERC7579Account(entryPoint, principal);
        _fund(address(rogue), 1000e6);
        vm.prank(principal);
        rogue.ownerExecute(address(topUps), 0, abi.encodeCall(TopUpExecutor.onInstall, ("")));
        vm.prank(address(rogue));
        topUps.setRule(agent, address(usdc), REFILL_TO, WHEN_BELOW, MAX_PER_DAY);
        vm.expectRevert(abi.encodeWithSelector(MockERC7579Account.Unauthorized.selector, address(topUps)));
        topUps.topUp(address(rogue), agent);
    }

    function test_topUp_rejectsFeeOnTransferAndFalseReturningTokens() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(address(treasury), 1000);
        _ownerCall(abi.encodeCall(TopUpExecutor.setRule, (agent2, address(fot), 100, 100, 1000)));
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.TopUpAmountMismatch.selector, 100, 99));
        topUps.topUp(address(treasury), agent2);

        FalseReturnToken bad = new FalseReturnToken();
        bad.mint(address(treasury), 1000);
        bad.setFailTransfers(true);
        address agent3 = makeAddr("agent-3");
        _ownerCall(abi.encodeCall(TopUpExecutor.setRule, (agent3, address(bad), 100, 100, 1000)));
        vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.TopUpAmountMismatch.selector, 100, 0));
        topUps.topUp(address(treasury), agent3);
    }

    function test_topUp_reentrancyBlocked() public {
        CallbackToken cbk = new CallbackToken();
        cbk.mint(address(treasury), 1000);
        _ownerCall(abi.encodeCall(TopUpExecutor.setRule, (agent2, address(cbk), 100, 100, 1000)));
        cbk.setCallback(address(topUps), abi.encodeCall(TopUpExecutor.topUp, (address(treasury), agent2)));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        topUps.topUp(address(treasury), agent2);
    }

    function test_withPolicyHookOnTreasury_agentMustBeAllowedRecipient() public {
        AgentPolicyHook hook = new AgentPolicyHook();
        IAgentPolicyHook.PolicyConfig memory c;
        c.tokenLimits = new IAgentPolicyHook.TokenLimitConfig[](1);
        c.tokenLimits[0] = IAgentPolicyHook.TokenLimitConfig(address(usdc), 1000e6, 5000e6);
        c.recipientAllowlistEnabled = true;
        vm.prank(entryPoint);
        treasury.installModule(MODULE_TYPE_HOOK, address(hook), abi.encode(c));

        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.RecipientNotAllowed.selector, agent));
        topUps.topUp(address(treasury), agent);
        vm.prank(principal);
        treasury.ownerExecute(address(hook), 0, abi.encodeCall(AgentPolicyHook.setRecipient, (agent, true)));
        topUps.topUp(address(treasury), agent);
        assertEq(hook.spentToday(address(treasury), address(usdc)), 100e6);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_topUp_amountFormula(
        uint256 agentBalance,
        uint256 treasuryBalance,
        uint128 refillTo,
        uint128 whenBelow,
        uint128 maxPerDay,
        uint256 alreadyToday
    ) public {
        refillTo = uint128(bound(refillTo, 1, 1e15));
        whenBelow = uint128(bound(whenBelow, 1, refillTo));
        maxPerDay = uint128(bound(maxPerDay, 1, 1e15));
        agentBalance = bound(agentBalance, 0, 2e15);
        treasuryBalance = bound(treasuryBalance, 0, 2e15);
        address a = makeAddr("fuzz-agent");
        _ownerCall(abi.encodeCall(TopUpExecutor.setRule, (a, address(usdc), refillTo, whenBelow, maxPerDay)));

        // consume part of today's cap first (via a real top-up from a full balance)
        alreadyToday = bound(alreadyToday, 0, maxPerDay);
        if (alreadyToday > 0 && alreadyToday <= refillTo) {
            topUps.topUp(address(treasury), a); // agent at 0 → tops up min(refillTo, maxPerDay)
            uint256 received = usdc.balanceOf(a);
            vm.prank(a);
            usdc.transfer(stranger, received);
        }
        uint256 spent = topUps.spentToday(address(treasury), a);

        // set balances (read the balance before pranking: the prank applies to the very next call)
        uint256 drain = usdc.balanceOf(address(treasury));
        vm.prank(principal);
        treasury.ownerExecute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (principal, drain)));
        _fund(address(treasury), treasuryBalance);
        _fund(a, agentBalance);

        uint256 expected;
        if (agentBalance < whenBelow) {
            uint256 remaining = spent >= maxPerDay ? 0 : maxPerDay - spent;
            expected = refillTo - agentBalance;
            if (remaining < expected) expected = remaining;
            if (treasuryBalance < expected) expected = treasuryBalance;
        }
        assertEq(topUps.previewTopUp(address(treasury), a), expected);
        if (agentBalance >= whenBelow) {
            vm.expectRevert(
                abi.encodeWithSelector(ITopUpExecutor.NotBelowThreshold.selector, a, agentBalance, whenBelow)
            );
            topUps.topUp(address(treasury), a);
        } else if (expected == 0) {
            vm.expectRevert(abi.encodeWithSelector(ITopUpExecutor.NothingToTopUp.selector, address(treasury), a));
            topUps.topUp(address(treasury), a);
        } else {
            assertEq(topUps.topUp(address(treasury), a), expected);
            assertEq(usdc.balanceOf(a), agentBalance + expected);
            assertLe(usdc.balanceOf(a), refillTo);
            assertLe(topUps.spentToday(address(treasury), a), maxPerDay);
        }
    }
}
