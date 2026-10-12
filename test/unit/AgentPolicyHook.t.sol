// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgentEscrow} from "../../src/AgentEscrow.sol";
import {AgentPolicyHook} from "../../src/AgentPolicyHook.sol";
import {PaymentStreams} from "../../src/PaymentStreams.sol";
import {TimeLockVaults} from "../../src/TimeLockVaults.sol";
import {IAgentEscrow} from "../../src/interfaces/IAgentEscrow.sol";
import {IAgentPolicyHook} from "../../src/interfaces/IAgentPolicyHook.sol";
import {
    CALLTYPE_BATCH,
    CALLTYPE_DELEGATECALL,
    CALLTYPE_SINGLE,
    CALLTYPE_STATIC,
    EXECTYPE_DEFAULT,
    EXECTYPE_TRY,
    Execution,
    IERC7579Execution,
    IERC7579ModuleConfig,
    MODULE_TYPE_EXECUTOR,
    MODULE_TYPE_HOOK
} from "../../src/interfaces/IERC7579.sol";
import {IPaymentStreams} from "../../src/interfaces/IPaymentStreams.sol";
import {ITimeLockVaults} from "../../src/interfaces/ITimeLockVaults.sol";
import {MockERC7579Account} from "../mocks/MockERC7579Account.sol";
import {TestExecutor} from "../mocks/TestExecutor.sol";
import {TestToken} from "../mocks/TestTokens.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract AgentPolicyHookTest is BaseTest {
    AgentPolicyHook internal hook;
    MockERC7579Account internal account;
    AgentEscrow internal escrow;
    PaymentStreams internal streams;
    TimeLockVaults internal vaults;
    TestToken internal other;

    address internal principal = makeAddr("principal");
    address internal merchant = makeAddr("merchant");
    address internal attacker = makeAddr("attacker");

    uint128 internal constant PER_TX = 25 * 1e6;
    uint128 internal constant PER_DAY = 200 * 1e6;

    bytes4 internal constant INCREASE_ALLOWANCE = 0x39509351;
    bytes4 internal constant DECREASE_ALLOWANCE = 0xa457c2d7;

    function setUp() public override {
        super.setUp();
        hook = new AgentPolicyHook();
        account = new MockERC7579Account(entryPoint, principal);
        escrow = new AgentEscrow(address(0), address(0));
        streams = new PaymentStreams(address(0));
        vaults = new TimeLockVaults(address(0));
        other = new TestToken("Other", "OTH");
        _fund(address(account), 10_000 * USDC_UNIT);
        other.mint(address(account), 100 ether);
        vm.deal(address(account), 10 ether);
        _install(_defaultConfig(false));
    }

    // ------------------------------------------------------------------ helpers

    function _defaultConfig(bool allowlistEnabled) internal view returns (IAgentPolicyHook.PolicyConfig memory c) {
        c.tokenLimits = new IAgentPolicyHook.TokenLimitConfig[](1);
        c.tokenLimits[0] = IAgentPolicyHook.TokenLimitConfig(address(usdc), PER_TX, PER_DAY);
        c.allowedRecipients = new address[](1);
        c.allowedRecipients[0] = merchant;
        c.allowedContracts = new IAgentPolicyHook.ContractConfig[](3);
        c.allowedContracts[0] =
            IAgentPolicyHook.ContractConfig(address(escrow), IAgentPolicyHook.ContractKind.AgentEscrow);
        c.allowedContracts[1] =
            IAgentPolicyHook.ContractConfig(address(streams), IAgentPolicyHook.ContractKind.PaymentStreams);
        c.allowedContracts[2] =
            IAgentPolicyHook.ContractConfig(address(vaults), IAgentPolicyHook.ContractKind.TimeLockVaults);
        c.recipientAllowlistEnabled = allowlistEnabled;
    }

    function _install(IAgentPolicyHook.PolicyConfig memory c) internal {
        vm.prank(entryPoint);
        account.installModule(MODULE_TYPE_HOOK, address(hook), abi.encode(c));
    }

    function _uninstall() internal {
        vm.prank(entryPoint);
        account.uninstallModule(MODULE_TYPE_HOOK, address(hook), "");
    }

    /// @dev Agent path: a user operation through the entry point (hooked).
    function _exec(address target, uint256 value, bytes memory data) internal {
        vm.prank(entryPoint);
        account.execute(_singleMode(), _single(target, value, data));
    }

    function _execBatch(Execution[] memory executions) internal {
        vm.prank(entryPoint);
        account.execute(_batchMode(), _batch(executions));
    }

    /// @dev Owner path: the Safe's native execTransaction model (never hooked).
    function _ownerExec(address target, uint256 value, bytes memory data) internal {
        vm.prank(principal);
        account.ownerExecute(target, value, data);
    }

    function _transfer(address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.transfer, (to, amount));
    }

    function _usdcTransfer(address to, uint256 amount) internal {
        _exec(address(usdc), 0, _transfer(to, amount));
    }

    function _ownerConfig(bytes memory data) internal {
        _ownerExec(address(hook), 0, data);
    }

    // ------------------------------------------------------------------ lifecycle

    function test_install_appliesConfig() public view {
        assertTrue(hook.isInitialized(address(account)));
        assertTrue(hook.isModuleType(MODULE_TYPE_HOOK));
        assertFalse(hook.isModuleType(MODULE_TYPE_EXECUTOR));
        (uint128 perTx, uint128 perDay) = hook.tokenLimit(address(account), address(usdc));
        assertEq(perTx, PER_TX);
        assertEq(perDay, PER_DAY);
        assertTrue(hook.isRecipientAllowed(address(account), merchant));
        assertEq(
            uint8(hook.contractKind(address(account), address(escrow))),
            uint8(IAgentPolicyHook.ContractKind.AgentEscrow)
        );
        assertFalse(hook.recipientAllowlistEnabled(address(account)));
        assertEq(hook.remainingToday(address(account), address(usdc)), PER_DAY);
    }

    function test_install_emptyData_locksEverythingDown() public {
        _uninstall();
        vm.prank(entryPoint);
        account.installModule(MODULE_TYPE_HOOK, address(hook), "");
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.TargetNotAllowed.selector, address(usdc)));
        account.execute(_singleMode(), _single(address(usdc), 0, _transfer(merchant, 1)));
    }

    function test_install_twiceReverts() public {
        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.AlreadyInitialized.selector, address(account)));
        hook.onInstall("");
    }

    function test_uninstall_discardsConfigAndSpend() public {
        _usdcTransfer(merchant, PER_TX);
        assertEq(hook.spentToday(address(account), address(usdc)), PER_TX);
        _uninstall();
        assertFalse(hook.isInitialized(address(account)));
        assertFalse(account.isModuleInstalled(MODULE_TYPE_HOOK, address(hook), ""));

        // without the hook the agent path is unrestricted (the account's own choice)
        _usdcTransfer(attacker, 1000 * USDC_UNIT);

        vm.prank(entryPoint);
        account.installModule(MODULE_TYPE_HOOK, address(hook), "");
        (uint128 perTx, uint128 perDay) = hook.tokenLimit(address(account), address(usdc));
        assertEq(perTx + perDay, 0, "old epoch is gone");
        assertEq(hook.spentToday(address(account), address(usdc)), 0);
        assertFalse(hook.isRecipientAllowed(address(account), merchant));
    }

    function test_onUninstall_neverReverts() public {
        vm.prank(stranger);
        hook.onUninstall("");
        hook.postCheck("");
        vm.prank(address(account));
        hook.postCheck(hex"deadbeef");
    }

    /// @notice Even if the hook's state is desynchronised from the account (e.g. the owner called onUninstall
    ///         directly), executions fail closed and the owner can still uninstall the module.
    function test_desyncedHook_failsClosed_butCanAlwaysBeUninstalled() public {
        _ownerExec(address(hook), 0, abi.encodeCall(AgentPolicyHook.onUninstall, ("")));
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.NotInitialized.selector, address(account)));
        account.execute(_singleMode(), _single(address(usdc), 0, _transfer(merchant, 1)));

        _ownerExec(
            address(account),
            0,
            abi.encodeCall(IERC7579ModuleConfig.uninstallModule, (MODULE_TYPE_HOOK, address(hook), ""))
        );
        assertEq(account.hook(), address(0));
        _usdcTransfer(merchant, 1);
    }

    // ------------------------------------------------------------------ configuration

    function test_config_onlyInstalledAccounts() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.NotInitialized.selector, stranger));
        hook.setTokenLimit(address(usdc), 1, 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.NotInitialized.selector, stranger));
        hook.setRecipient(merchant, true);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.NotInitialized.selector, stranger));
        hook.setRecipientAllowlistEnabled(true);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.NotInitialized.selector, stranger));
        hook.setContract(address(escrow), IAgentPolicyHook.ContractKind.Generic);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.NotInitialized.selector, stranger));
        hook.applyConfig(_defaultConfig(true));
        vm.stopPrank();
    }

    function test_config_ownerPathWorks_andEmits() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit IAgentPolicyHook.TokenLimitSet(address(account), address(other), 1 ether, 5 ether);
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setTokenLimit, (address(other), 1 ether, 5 ether)));
        vm.expectEmit(true, true, false, true, address(hook));
        emit IAgentPolicyHook.RecipientSet(address(account), stranger, true);
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setRecipient, (stranger, true)));
        vm.expectEmit(true, false, false, true, address(hook));
        emit IAgentPolicyHook.RecipientAllowlistSet(address(account), true);
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setRecipientAllowlistEnabled, (true)));
        vm.expectEmit(true, true, false, true, address(hook));
        emit IAgentPolicyHook.ContractSet(address(account), keeper, IAgentPolicyHook.ContractKind.Generic);
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setContract, (keeper, IAgentPolicyHook.ContractKind.Generic)));

        (uint128 perTx, uint128 perDay) = hook.tokenLimit(address(account), address(other));
        assertEq(perTx, 1 ether);
        assertEq(perDay, 5 ether);
        assertTrue(hook.recipientAllowlistEnabled(address(account)));
        assertTrue(hook.isRecipientAllowed(address(account), stranger));
        assertEq(uint8(hook.contractKind(address(account), keeper)), uint8(IAgentPolicyHook.ContractKind.Generic));

        // removals
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setTokenLimit, (address(other), 0, 0)));
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setRecipient, (stranger, false)));
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setContract, (keeper, IAgentPolicyHook.ContractKind.None)));
        (perTx, perDay) = hook.tokenLimit(address(account), address(other));
        assertEq(perTx + perDay, 0);
        assertFalse(hook.isRecipientAllowed(address(account), stranger));
        assertEq(uint8(hook.contractKind(address(account), keeper)), 0);
    }

    function test_config_validation() public {
        vm.startPrank(address(account));
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.InvalidTokenLimit.selector, address(usdc), 0, 10));
        hook.setTokenLimit(address(usdc), 0, 10);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.InvalidTokenLimit.selector, address(usdc), 11, 10));
        hook.setTokenLimit(address(usdc), 11, 10);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.InvalidAddress.selector, address(account)));
        hook.setTokenLimit(address(account), 1, 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.InvalidAddress.selector, address(hook)));
        hook.setTokenLimit(address(hook), 1, 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.InvalidAddress.selector, address(0)));
        hook.setRecipient(address(0), true);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.InvalidAddress.selector, address(0)));
        hook.setContract(address(0), IAgentPolicyHook.ContractKind.Generic);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.InvalidAddress.selector, address(account)));
        hook.setContract(address(account), IAgentPolicyHook.ContractKind.Generic);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.InvalidAddress.selector, address(hook)));
        hook.setContract(address(hook), IAgentPolicyHook.ContractKind.Generic);
        vm.stopPrank();
    }

    function test_config_applyConfigInBulk() public {
        IAgentPolicyHook.PolicyConfig memory c;
        c.tokenLimits = new IAgentPolicyHook.TokenLimitConfig[](1);
        c.tokenLimits[0] = IAgentPolicyHook.TokenLimitConfig(address(other), 1, 2);
        c.allowedRecipients = new address[](1);
        c.allowedRecipients[0] = keeper;
        c.recipientAllowlistEnabled = true;
        _ownerConfig(abi.encodeCall(AgentPolicyHook.applyConfig, (c)));
        assertTrue(hook.recipientAllowlistEnabled(address(account)));
        assertTrue(hook.isRecipientAllowed(address(account), keeper));
        (, uint128 perDay) = hook.tokenLimit(address(account), address(other));
        assertEq(perDay, 2);
    }

    /// @notice The agent path can never reconfigure the hook, even if its session scope allowed calling it.
    function test_agentPath_cannotReconfigureHook() public {
        vm.prank(entryPoint);
        vm.expectRevert(IAgentPolicyHook.HookCallBlocked.selector);
        account.execute(
            _singleMode(),
            _single(
                address(hook),
                0,
                abi.encodeCall(AgentPolicyHook.setTokenLimit, (address(usdc), type(uint128).max, type(uint128).max))
            )
        );
        vm.prank(entryPoint);
        vm.expectRevert(IAgentPolicyHook.HookCallBlocked.selector);
        account.execute(_singleMode(), _single(address(hook), 0, abi.encodeCall(AgentPolicyHook.onUninstall, (""))));
    }

    // ------------------------------------------------------------------ caps

    function test_transfer_withinCaps_recordsSpend() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit IAgentPolicyHook.SpendRecorded(address(account), address(usdc), 10 * USDC_UNIT, 10 * USDC_UNIT);
        _usdcTransfer(merchant, 10 * USDC_UNIT);
        assertEq(usdc.balanceOf(merchant), 10 * USDC_UNIT);
        assertEq(hook.spentToday(address(account), address(usdc)), 10 * USDC_UNIT);
        assertEq(hook.remainingToday(address(account), address(usdc)), PER_DAY - 10 * USDC_UNIT);
    }

    function test_transfer_perTxCap() public {
        _usdcTransfer(merchant, PER_TX); // boundary passes
        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), PER_TX + 1, PER_TX)
        );
        account.execute(_singleMode(), _single(address(usdc), 0, _transfer(merchant, PER_TX + 1)));
    }

    function test_transfer_dailyCap_andUtcDayRollover() public {
        for (uint256 i; i < 8; ++i) {
            _usdcTransfer(merchant, PER_TX); // 8 * 25 = 200 = PER_DAY
        }
        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.DailyLimitExceeded.selector, address(usdc), PER_DAY + 1, PER_DAY)
        );
        account.execute(_singleMode(), _single(address(usdc), 0, _transfer(merchant, 1)));
        assertEq(hook.remainingToday(address(account), address(usdc)), 0);

        // one second before UTC midnight is still the same day
        vm.warp((block.timestamp / 1 days + 1) * 1 days - 1);
        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.DailyLimitExceeded.selector, address(usdc), PER_DAY + 1, PER_DAY)
        );
        account.execute(_singleMode(), _single(address(usdc), 0, _transfer(merchant, 1)));

        vm.warp(block.timestamp + 1);
        assertEq(hook.spentToday(address(account), address(usdc)), 0);
        _usdcTransfer(merchant, PER_TX);
    }

    function test_batch_aggregatesPerToken_forPerTxCap() public {
        Execution[] memory executions = new Execution[](2);
        executions[0] = Execution(address(usdc), 0, _transfer(merchant, 20 * USDC_UNIT));
        executions[1] = Execution(address(usdc), 0, _transfer(merchant, 20 * USDC_UNIT));
        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), 40 * USDC_UNIT, PER_TX)
        );
        account.execute(_batchMode(), _batch(executions));

        executions[1] = Execution(address(usdc), 0, _transfer(merchant, 5 * USDC_UNIT));
        _execBatch(executions);
        assertEq(hook.spentToday(address(account), address(usdc)), 25 * USDC_UNIT);
    }

    function test_batch_multipleTokensCappedIndependently() public {
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setTokenLimit, (address(other), 1 ether, 2 ether)));
        Execution[] memory executions = new Execution[](3);
        executions[0] = Execution(address(usdc), 0, _transfer(merchant, PER_TX));
        executions[1] = Execution(address(other), 0, _transfer(merchant, 0.5 ether));
        executions[2] = Execution(address(other), 0, _transfer(merchant, 0.5 ether));
        _execBatch(executions);
        assertEq(hook.spentToday(address(account), address(usdc)), PER_TX);
        assertEq(hook.spentToday(address(account), address(other)), 1 ether);
    }

    function test_tryMode_isEnforcedAndCountsSpend() public {
        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), PER_TX + 1, PER_TX)
        );
        account.execute(
            _mode(CALLTYPE_SINGLE, EXECTYPE_TRY), _single(address(usdc), 0, _transfer(merchant, PER_TX + 1))
        );

        // a failing call in try-mode still consumes allowance under the cap (conservative)
        usdc.blacklist(merchant);
        vm.prank(entryPoint);
        account.execute(_mode(CALLTYPE_SINGLE, EXECTYPE_TRY), _single(address(usdc), 0, _transfer(merchant, 10)));
        assertEq(usdc.balanceOf(merchant), 0);
        assertEq(hook.spentToday(address(account), address(usdc)), 10);
    }

    // ------------------------------------------------------------------ native value

    function test_native_requiresConfiguredLimits() public {
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.TokenNotConfigured.selector, address(0)));
        account.execute(_singleMode(), _single(merchant, 1 wei, ""));

        _ownerConfig(abi.encodeCall(AgentPolicyHook.setTokenLimit, (address(0), 0.01 ether, 0.05 ether)));
        _exec(merchant, 0.01 ether, "");
        assertEq(merchant.balance, 0.01 ether);
        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.PerTxLimitExceeded.selector, address(0), 0.02 ether, 0.01 ether)
        );
        account.execute(_singleMode(), _single(merchant, 0.02 ether, ""));
    }

    function test_native_valueToAllowlistedContractCounts() public {
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setTokenLimit, (address(0), 1 ether, 1 ether)));
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setContract, (keeper, IAgentPolicyHook.ContractKind.Generic)));
        _exec(keeper, 0.4 ether, hex"12345678");
        assertEq(hook.spentToday(address(account), address(0)), 0.4 ether);
    }

    // ------------------------------------------------------------------ recipients

    function test_recipientAllowlist() public {
        _usdcTransfer(attacker, 1); // disabled: any recipient
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setRecipientAllowlistEnabled, (true)));

        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.RecipientNotAllowed.selector, attacker));
        account.execute(_singleMode(), _single(address(usdc), 0, _transfer(attacker, 1)));

        _usdcTransfer(merchant, 1); // explicitly allowed
        _usdcTransfer(address(escrow), 1); // allowlisted contracts are trusted destinations
        _usdcTransfer(address(account), 1); // self-transfer is not an outflow
        assertEq(hook.spentToday(address(account), address(usdc)), 3);
    }

    function test_native_respectsRecipientAllowlist() public {
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setTokenLimit, (address(0), 1 ether, 1 ether)));
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setRecipientAllowlistEnabled, (true)));
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.RecipientNotAllowed.selector, attacker));
        account.execute(_singleMode(), _single(attacker, 1, ""));
        _exec(merchant, 1, "");
    }

    // ------------------------------------------------------------------ approvals and transferFrom

    function test_approve_onlyAllowlistedSpenders_andCounts() public {
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.SpenderNotAllowed.selector, attacker));
        account.execute(_singleMode(), _single(address(usdc), 0, abi.encodeCall(IERC20.approve, (attacker, 1))));

        _exec(address(usdc), 0, abi.encodeCall(IERC20.approve, (address(escrow), 20 * USDC_UNIT)));
        assertEq(usdc.allowance(address(account), address(escrow)), 20 * USDC_UNIT);
        assertEq(hook.spentToday(address(account), address(usdc)), 20 * USDC_UNIT);

        // an unlimited approval can never pass the per-tx cap
        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), type(uint256).max, PER_TX
            )
        );
        account.execute(
            _singleMode(),
            _single(address(usdc), 0, abi.encodeCall(IERC20.approve, (address(escrow), type(uint256).max)))
        );
    }

    function test_approve_revocationsAlwaysAllowed() public {
        _ownerExec(address(usdc), 0, abi.encodeCall(IERC20.approve, (attacker, 1000)));
        _exec(address(usdc), 0, abi.encodeCall(IERC20.approve, (attacker, 0)));
        assertEq(usdc.allowance(address(account), attacker), 0);
        // MockUSDC (OZ v5) lacks these FiatToken functions, so run them in try-mode: only the hook's verdict matters.
        vm.startPrank(entryPoint);
        account.execute(
            _mode(CALLTYPE_SINGLE, EXECTYPE_TRY),
            _single(address(usdc), 0, abi.encodeWithSelector(DECREASE_ALLOWANCE, attacker, 5))
        );
        account.execute(
            _mode(CALLTYPE_SINGLE, EXECTYPE_TRY),
            _single(address(usdc), 0, abi.encodeWithSelector(INCREASE_ALLOWANCE, attacker, 0))
        );
        vm.stopPrank();
        assertEq(hook.spentToday(address(account), address(usdc)), 0);
    }

    function test_increaseAllowance_isCappedLikeApprove() public {
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.SpenderNotAllowed.selector, attacker));
        account.execute(
            _singleMode(), _single(address(usdc), 0, abi.encodeWithSelector(INCREASE_ALLOWANCE, attacker, 1))
        );
        // MockUSDC has no increaseAllowance: try-mode lets the (failing) call through so we can observe accounting
        vm.prank(entryPoint);
        account.execute(
            _mode(CALLTYPE_SINGLE, EXECTYPE_TRY),
            _single(address(usdc), 0, abi.encodeWithSelector(INCREASE_ALLOWANCE, address(escrow), 7))
        );
        assertEq(hook.spentToday(address(account), address(usdc)), 7);
    }

    function test_transferFrom_intoAccountIsInflow_outwardIsCapped() public {
        // e.g. sweeping an agent's spend-key float back with an EIP-2612 allowance
        address spendKey = makeAddr("spend-key");
        _fund(spendKey, 1000 * USDC_UNIT);
        vm.prank(spendKey);
        usdc.approve(address(account), type(uint256).max);

        _exec(address(usdc), 0, abi.encodeCall(IERC20.transferFrom, (spendKey, address(account), 1000 * USDC_UNIT)));
        assertEq(hook.spentToday(address(account), address(usdc)), 0, "inflow");

        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), 1000 * USDC_UNIT, PER_TX
            )
        );
        account.execute(
            _singleMode(),
            _single(address(usdc), 0, abi.encodeCall(IERC20.transferFrom, (spendKey, attacker, 1000 * USDC_UNIT)))
        );
    }

    // ------------------------------------------------------------------ fail-closed target rules

    function test_unsupportedTokenSelectors_revert() public {
        bytes memory permitCall = abi.encodeWithSignature(
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            address(account),
            attacker,
            1,
            1,
            uint8(27),
            bytes32(0),
            bytes32(0)
        );
        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.UnsupportedTokenCall.selector, address(usdc), bytes4(permitCall))
        );
        account.execute(_singleMode(), _single(address(usdc), 0, permitCall));

        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.UnsupportedTokenCall.selector, address(usdc), bytes4(0))
        );
        account.execute(_singleMode(), _single(address(usdc), 0, hex"a905"));

        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.UnsupportedTokenCall.selector, address(usdc), bytes4(0))
        );
        account.execute(_singleMode(), _single(address(usdc), 1, ""));
    }

    function test_malformedTokenCalldata_reverts() public {
        vm.prank(entryPoint);
        vm.expectRevert(IAgentPolicyHook.MalformedExecution.selector);
        account.execute(
            _singleMode(), _single(address(usdc), 0, abi.encodePacked(IERC20.transfer.selector, uint256(1)))
        );
        // dirty upper bits in an address argument
        bytes memory dirty =
            abi.encodePacked(IERC20.transfer.selector, uint256(uint160(merchant)) | (uint256(1) << 200), uint256(1));
        vm.prank(entryPoint);
        vm.expectRevert(IAgentPolicyHook.MalformedExecution.selector);
        account.execute(_singleMode(), _single(address(usdc), 0, dirty));
    }

    function test_unknownTargets_failClosed() public {
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.TargetNotAllowed.selector, address(other)));
        account.execute(_singleMode(), _single(address(other), 0, _transfer(attacker, 1)));

        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.TargetNotAllowed.selector, stranger));
        account.execute(_singleMode(), _single(stranger, 0, hex"01"));

        // plain value-less empty calls are harmless no-ops
        _exec(stranger, 0, "");
    }

    function test_selfCalls_allowed_andNestedExecutionsStillEnforced() public {
        TestExecutor executor = new TestExecutor();
        _exec(
            address(account),
            0,
            abi.encodeCall(IERC7579ModuleConfig.installModule, (MODULE_TYPE_EXECUTOR, address(executor), ""))
        );
        assertTrue(account.isExecutor(address(executor)));

        bytes memory inner = abi.encodeCall(
            IERC7579Execution.execute, (_singleMode(), _single(address(usdc), 0, _transfer(attacker, PER_TX + 1)))
        );
        vm.prank(entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), PER_TX + 1, PER_TX)
        );
        account.execute(_singleMode(), _single(address(account), 0, inner));
    }

    function test_unsupportedModes_revert() public {
        bytes memory transferCall = _transfer(merchant, 1);
        vm.startPrank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.UnsupportedCallType.selector, CALLTYPE_DELEGATECALL));
        account.execute(_mode(CALLTYPE_DELEGATECALL, EXECTYPE_DEFAULT), abi.encodePacked(address(usdc), transferCall));
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.UnsupportedCallType.selector, CALLTYPE_STATIC));
        account.execute(_mode(CALLTYPE_STATIC, EXECTYPE_DEFAULT), _single(address(usdc), 0, transferCall));
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.UnsupportedExecType.selector, bytes1(0x02)));
        account.execute(_mode(CALLTYPE_SINGLE, bytes1(0x02)), _single(address(usdc), 0, transferCall));
        bytes32 customMode =
            bytes32(abi.encodePacked(CALLTYPE_SINGLE, EXECTYPE_DEFAULT, bytes4(0), bytes4(0xdeadbeef), bytes22(0)));
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.UnsupportedModeSelector.selector, bytes4(0xdeadbeef)));
        account.execute(customMode, _single(address(usdc), 0, transferCall));
        vm.expectRevert(IAgentPolicyHook.MalformedExecution.selector);
        account.execute(_singleMode(), abi.encodePacked(address(usdc), uint128(0)));
        vm.stopPrank();
    }

    function test_executeFromExecutor_isEnforced() public {
        TestExecutor executor = new TestExecutor();
        vm.prank(entryPoint);
        account.installModule(MODULE_TYPE_EXECUTOR, address(executor), "");
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), PER_TX + 1, PER_TX)
        );
        executor.run(address(account), _singleMode(), _single(address(usdc), 0, _transfer(merchant, PER_TX + 1)));
        executor.run(address(account), _singleMode(), _single(address(usdc), 0, _transfer(merchant, PER_TX)));
        assertEq(usdc.balanceOf(merchant), PER_TX);
    }

    function test_preCheck_directCalls() public {
        bytes memory executeCall = abi.encodeCall(
            IERC7579Execution.execute, (_singleMode(), _single(address(usdc), 0, _transfer(merchant, PER_TX + 1)))
        );
        // non-execution selectors pass even for accounts that never installed the hook
        vm.prank(stranger);
        hook.preCheck(stranger, 0, abi.encodeCall(IERC7579ModuleConfig.uninstallModule, (4, address(hook), "")));
        vm.prank(stranger);
        hook.preCheck(stranger, 0, hex"00");
        // executions from uninitialised accounts fail closed
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.NotInitialized.selector, stranger));
        hook.preCheck(stranger, 0, executeCall);
        // Safe7579 appends the 20-byte ERC-2771 sender: decoding tolerates it
        vm.prank(address(account));
        vm.expectRevert(
            abi.encodeWithSelector(IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), PER_TX + 1, PER_TX)
        );
        hook.preCheck(entryPoint, 0, abi.encodePacked(executeCall, entryPoint));
    }

    // ------------------------------------------------------------------ Agent Bank contract kinds

    function test_escrow_approveAndLockInOneBatch() public {
        Execution[] memory executions = new Execution[](2);
        executions[0] = Execution(address(usdc), 0, abi.encodeCall(IERC20.approve, (address(escrow), PER_TX)));
        executions[1] = Execution(
            address(escrow),
            0,
            abi.encodeCall(
                IAgentEscrow.lock,
                (address(usdc), merchant, PER_TX, uint64(block.timestamp + 1 days), address(0), address(0), 0, 0, 0)
            )
        );
        _execBatch(executions);
        assertEq(usdc.balanceOf(address(escrow)), PER_TX);
        assertEq(hook.spentToday(address(account), address(usdc)), PER_TX, "counted once, at the approval");
    }

    function test_escrow_lockPayeeMustPassAllowlist() public {
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setRecipientAllowlistEnabled, (true)));
        _exec(address(usdc), 0, abi.encodeCall(IERC20.approve, (address(escrow), 2 * USDC_UNIT)));
        bytes memory lockAttacker = abi.encodeCall(
            IAgentEscrow.lock,
            (address(usdc), attacker, USDC_UNIT, uint64(block.timestamp + 1 days), address(0), address(0), 0, 0, 0)
        );
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.RecipientNotAllowed.selector, attacker));
        account.execute(_singleMode(), _single(address(escrow), 0, lockAttacker));

        bytes memory lockMerchant = abi.encodeCall(
            IAgentEscrow.lock,
            (address(usdc), merchant, USDC_UNIT, uint64(block.timestamp + 1 days), address(0), address(0), 0, 0, 0)
        );
        _exec(address(escrow), 0, lockMerchant);
        // other escrow functions are not payee-routing and pass
        _exec(address(escrow), 0, abi.encodeCall(IAgentEscrow.release, (1)));
        assertEq(usdc.balanceOf(merchant), USDC_UNIT);
    }

    function test_streams_createPayeeMustPassAllowlist() public {
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setRecipientAllowlistEnabled, (true)));
        _exec(address(usdc), 0, abi.encodeCall(IERC20.approve, (address(streams), 10 * USDC_UNIT)));
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.RecipientNotAllowed.selector, attacker));
        account.execute(
            _singleMode(),
            _single(
                address(streams),
                0,
                abi.encodeCall(IPaymentStreams.createStream, (address(usdc), attacker, 10 * USDC_UNIT, 1, 1, 0, 0))
            )
        );
        _exec(
            address(streams),
            0,
            abi.encodeCall(IPaymentStreams.createStream, (address(usdc), merchant, 10 * USDC_UNIT, 1, 1, 0, 0))
        );
        assertEq(streams.streamCount(), 1);
    }

    function test_vaults_depositOnlyIntoOwnOrAllowedAccountsVaults() public {
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setRecipientAllowlistEnabled, (true)));
        vm.prank(address(account));
        uint256 own = vaults.createVault(address(usdc), uint64(block.timestamp + 30 days), principal);
        vm.prank(attacker);
        uint256 foreign = vaults.createVault(address(usdc), uint64(block.timestamp + 1), stranger);

        _exec(address(usdc), 0, abi.encodeCall(IERC20.approve, (address(vaults), 10 * USDC_UNIT)));
        _exec(address(vaults), 0, abi.encodeCall(ITimeLockVaults.deposit, (own, 5 * USDC_UNIT)));
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.RecipientNotAllowed.selector, attacker));
        account.execute(
            _singleMode(), _single(address(vaults), 0, abi.encodeCall(ITimeLockVaults.deposit, (foreign, 5)))
        );
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.RecipientNotAllowed.selector, address(0)));
        account.execute(_singleMode(), _single(address(vaults), 0, abi.encodeCall(ITimeLockVaults.deposit, (999, 5))));
        assertEq(vaults.getVault(own).balance, 5 * USDC_UNIT);
    }

    function test_genericContract_isTrustedToRoute() public {
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setRecipientAllowlistEnabled, (true)));
        _ownerConfig(
            abi.encodeCall(AgentPolicyHook.setContract, (address(escrow), IAgentPolicyHook.ContractKind.Generic))
        );
        _exec(address(usdc), 0, abi.encodeCall(IERC20.approve, (address(escrow), USDC_UNIT)));
        // with Generic kind the hook does not inspect payees (documented trust delegation)
        _exec(
            address(escrow),
            0,
            abi.encodeCall(
                IAgentEscrow.lock,
                (address(usdc), attacker, USDC_UNIT, uint64(block.timestamp + 1 days), address(0), address(0), 0, 0, 0)
            )
        );
        assertEq(escrow.escrowCount(), 1);
    }

    // ------------------------------------------------------------------ the owner can always exit

    function test_ownerExitPath_neverPassesThroughHook() public {
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setRecipientAllowlistEnabled, (true)));
        uint256 balance = usdc.balanceOf(address(account));
        // far above every cap, to a non-allowlisted address: the owner's native path is never hooked
        _ownerExec(address(usdc), 0, _transfer(principal, balance));
        _ownerExec(principal, 1 ether, "");
        assertEq(usdc.balanceOf(principal), balance);
        assertEq(principal.balance, 1 ether);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_caps_singleTransfers(uint256[6] memory amounts) public {
        uint256 spent;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = bound(amounts[i], 1, 2 * PER_TX);
            vm.prank(entryPoint);
            if (amount > PER_TX) {
                vm.expectRevert(
                    abi.encodeWithSelector(IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), amount, PER_TX)
                );
                account.execute(_singleMode(), _single(address(usdc), 0, _transfer(merchant, amount)));
            } else if (spent + amount > PER_DAY) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IAgentPolicyHook.DailyLimitExceeded.selector, address(usdc), spent + amount, PER_DAY
                    )
                );
                account.execute(_singleMode(), _single(address(usdc), 0, _transfer(merchant, amount)));
            } else {
                account.execute(_singleMode(), _single(address(usdc), 0, _transfer(merchant, amount)));
                spent += amount;
            }
            assertEq(hook.spentToday(address(account), address(usdc)), spent);
            assertEq(usdc.balanceOf(merchant), spent);
        }
    }

    function testFuzz_batchSplitting_cannotBypassPerTxCap(uint8 parts, uint256 total) public {
        parts = uint8(bound(parts, 1, 12));
        total = bound(total, parts, 3 * PER_TX);
        Execution[] memory executions = new Execution[](parts);
        uint256 each = total / parts;
        uint256 sum;
        for (uint256 i; i < parts; ++i) {
            uint256 amount = i == parts - 1 ? total - sum : each;
            executions[i] = Execution(address(usdc), 0, _transfer(merchant, amount));
            sum += amount;
        }
        vm.prank(entryPoint);
        if (total > PER_TX) {
            vm.expectRevert(
                abi.encodeWithSelector(IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), total, PER_TX)
            );
        }
        account.execute(_batchMode(), _batch(executions));
    }

    function testFuzz_recipientAllowlist(address recipient) public {
        vm.assume(recipient != address(0) && recipient != address(account) && recipient != merchant);
        vm.assume(recipient != address(escrow) && recipient != address(streams) && recipient != address(vaults));
        vm.assume(!usdc.isBlacklisted(recipient));
        _ownerConfig(abi.encodeCall(AgentPolicyHook.setRecipientAllowlistEnabled, (true)));
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.RecipientNotAllowed.selector, recipient));
        account.execute(_singleMode(), _single(address(usdc), 0, _transfer(recipient, 1)));
    }
}
