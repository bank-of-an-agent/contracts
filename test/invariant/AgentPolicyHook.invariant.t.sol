// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {AgentEscrow} from "../../src/AgentEscrow.sol";
import {AgentPolicyHook} from "../../src/AgentPolicyHook.sol";
import {IAgentEscrow} from "../../src/interfaces/IAgentEscrow.sol";
import {IAgentPolicyHook} from "../../src/interfaces/IAgentPolicyHook.sol";
import {
    CALLTYPE_SINGLE,
    EXECTYPE_TRY,
    Execution,
    MODE_BATCH_DEFAULT,
    MODE_SINGLE_DEFAULT,
    MODULE_TYPE_HOOK
} from "../../src/interfaces/IERC7579.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockERC7579Account} from "../mocks/MockERC7579Account.sol";
import {BaseTest} from "../utils/BaseTest.sol";

/// @notice Plays a compromised agent: issues arbitrary executions through the entry point.
contract HookHandler is Test {
    MockERC7579Account public immutable account;
    AgentPolicyHook public immutable hook;
    AgentEscrow public immutable escrow;
    MockUSDC public immutable usdc;
    address public immutable entryPoint;
    address public immutable merchant = makeAddr("inv.merchant");
    address public immutable attacker = makeAddr("inv.attacker");
    address public immutable attacker2 = makeAddr("inv.attacker2");

    uint128 public immutable perTx;
    uint128 public immutable perDay;
    uint128 public immutable nativePerDay;

    mapping(uint256 day => uint256) public ghostCommitted;
    mapping(uint256 day => uint256) public ghostNativeCommitted;
    uint256 public ghostTotalCommitted;
    mapping(bytes32 action => uint256) public calls;

    constructor(
        MockERC7579Account account_,
        AgentPolicyHook hook_,
        AgentEscrow escrow_,
        MockUSDC usdc_,
        address entryPoint_,
        uint128 perTx_,
        uint128 perDay_,
        uint128 nativePerDay_
    ) {
        account = account_;
        hook = hook_;
        escrow = escrow_;
        usdc = usdc_;
        entryPoint = entryPoint_;
        perTx = perTx_;
        perDay = perDay_;
        nativePerDay = nativePerDay_;
    }

    function transfer(uint256 recipientSeed, uint256 amount, bool tryMode) external {
        address[4] memory recipients = [merchant, attacker, address(escrow), attacker2];
        address to = recipients[recipientSeed % 4];
        amount = bound(amount, 1, 2 * uint256(perTx));
        bytes32 mode =
            tryMode ? bytes32(abi.encodePacked(CALLTYPE_SINGLE, EXECTYPE_TRY, bytes30(0))) : MODE_SINGLE_DEFAULT;
        vm.prank(entryPoint);
        try account.execute(
            mode, abi.encodePacked(address(usdc), uint256(0), abi.encodeCall(IERC20.transfer, (to, amount)))
        ) {
            _commit(amount);
            calls["transfer"]++;
        } catch {
            calls["transfer.blocked"]++;
        }
    }

    function approve(uint256 spenderSeed, uint256 amount) external {
        address spender = spenderSeed % 2 == 0 ? address(escrow) : attacker;
        amount = bound(amount, 0, 2 * uint256(perTx));
        vm.prank(entryPoint);
        try account.execute(
            MODE_SINGLE_DEFAULT,
            abi.encodePacked(address(usdc), uint256(0), abi.encodeCall(IERC20.approve, (spender, amount)))
        ) {
            _commit(amount);
            calls["approve"]++;
        } catch {
            calls["approve.blocked"]++;
        }
    }

    function lockInEscrow(uint256 payeeSeed, uint256 amount) external {
        address payee = payeeSeed % 2 == 0 ? merchant : attacker;
        amount = bound(amount, 1, 2 * uint256(perTx));
        Execution[] memory executions = new Execution[](2);
        executions[0] = Execution(address(usdc), 0, abi.encodeCall(IERC20.approve, (address(escrow), amount)));
        executions[1] = Execution(
            address(escrow),
            0,
            abi.encodeCall(
                IAgentEscrow.lock,
                (address(usdc), payee, amount, uint64(block.timestamp + 1 days), address(0), address(0), 0, 0, 0)
            )
        );
        vm.prank(entryPoint);
        try account.execute(MODE_BATCH_DEFAULT, abi.encode(executions)) {
            _commit(amount);
            calls["lock"]++;
        } catch {
            calls["lock.blocked"]++;
        }
    }

    function splitTransfer(uint8 parts, uint256 total) external {
        parts = uint8(bound(parts, 2, 6));
        total = bound(total, parts, 2 * uint256(perTx));
        Execution[] memory executions = new Execution[](parts);
        uint256 each = total / parts;
        for (uint256 i; i < parts; ++i) {
            uint256 amount = i == parts - 1 ? total - each * (parts - 1) : each;
            executions[i] = Execution(address(usdc), 0, abi.encodeCall(IERC20.transfer, (merchant, amount)));
        }
        vm.prank(entryPoint);
        try account.execute(MODE_BATCH_DEFAULT, abi.encode(executions)) {
            _commit(total);
            calls["split"]++;
        } catch {
            calls["split.blocked"]++;
        }
    }

    function sendNative(uint256 recipientSeed, uint256 amount) external {
        address to = recipientSeed % 2 == 0 ? merchant : attacker;
        amount = bound(amount, 1, uint256(nativePerDay));
        vm.prank(entryPoint);
        try account.execute(MODE_SINGLE_DEFAULT, abi.encodePacked(to, amount, "")) {
            ghostNativeCommitted[block.timestamp / 1 days] += amount;
            calls["native"]++;
        } catch {
            calls["native.blocked"]++;
        }
    }

    function reconfigureViaAgentPath(uint128 newPerTx) external {
        vm.prank(entryPoint);
        try account.execute(
            MODE_SINGLE_DEFAULT,
            abi.encodePacked(
                address(hook),
                uint256(0),
                abi.encodeCall(AgentPolicyHook.setTokenLimit, (address(usdc), newPerTx, newPerTx))
            )
        ) {
            calls["reconfigure.SUCCEEDED"]++;
        } catch {
            calls["reconfigure.blocked"]++;
        }
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 days));
        calls["warp"]++;
    }

    function _commit(uint256 amount) private {
        ghostCommitted[block.timestamp / 1 days] += amount;
        ghostTotalCommitted += amount;
    }
}

contract AgentPolicyHookInvariantTest is BaseTest {
    AgentPolicyHook internal hook;
    MockERC7579Account internal account;
    AgentEscrow internal escrow;
    HookHandler internal handler;

    uint128 internal constant PER_TX = 25e6;
    uint128 internal constant PER_DAY = 200e6;
    uint128 internal constant NATIVE_PER_DAY = 0.05 ether;
    uint256 internal constant START_BALANCE = 1_000_000e6;

    function setUp() public override {
        super.setUp();
        hook = new AgentPolicyHook();
        escrow = new AgentEscrow(address(0), address(0));
        account = new MockERC7579Account(entryPoint, makeAddr("inv.principal"));
        _fund(address(account), START_BALANCE);
        vm.deal(address(account), 100 ether);

        handler = new HookHandler(account, hook, escrow, usdc, entryPoint, PER_TX, PER_DAY, NATIVE_PER_DAY);

        IAgentPolicyHook.PolicyConfig memory c;
        c.tokenLimits = new IAgentPolicyHook.TokenLimitConfig[](2);
        c.tokenLimits[0] = IAgentPolicyHook.TokenLimitConfig(address(usdc), PER_TX, PER_DAY);
        c.tokenLimits[1] = IAgentPolicyHook.TokenLimitConfig(address(0), NATIVE_PER_DAY, NATIVE_PER_DAY);
        c.allowedRecipients = new address[](1);
        c.allowedRecipients[0] = handler.merchant();
        c.allowedContracts = new IAgentPolicyHook.ContractConfig[](1);
        c.allowedContracts[0] =
            IAgentPolicyHook.ContractConfig(address(escrow), IAgentPolicyHook.ContractKind.AgentEscrow);
        c.recipientAllowlistEnabled = true;
        vm.prank(entryPoint);
        account.installModule(MODULE_TYPE_HOOK, address(hook), abi.encode(c));

        targetContract(address(handler));
    }

    /// @notice Whatever the agent tries, committed outflow (transfers + approvals) per UTC day never exceeds the cap,
    ///         and the hook's own counter matches.
    function invariant_dailyCapHolds() public view {
        uint256 today = block.timestamp / 1 days;
        assertLe(handler.ghostCommitted(today), PER_DAY);
        assertEq(hook.spentToday(address(account), address(usdc)), handler.ghostCommitted(today));
        assertLe(handler.ghostNativeCommitted(today), NATIVE_PER_DAY);
    }

    /// @notice The account never lost more than it committed under the policy.
    function invariant_outflowBoundedByCommitted() public view {
        assertLe(START_BALANCE - usdc.balanceOf(address(account)), handler.ghostTotalCommitted());
    }

    /// @notice Non-allowlisted addresses never receive funds or allowances, directly or through the escrow.
    function invariant_recipientAllowlistHolds() public view {
        assertEq(usdc.balanceOf(handler.attacker()), 0);
        assertEq(usdc.balanceOf(handler.attacker2()), 0);
        assertEq(handler.attacker().balance, 0);
        assertEq(usdc.allowance(address(account), handler.attacker()), 0);
        uint256 n = escrow.escrowCount();
        for (uint256 id = 1; id <= n; ++id) {
            assertEq(escrow.getEscrow(id).payee, handler.merchant());
        }
    }

    /// @notice Sanity: each run mixes allowed and blocked spending, so the invariants are not vacuous.
    function afterInvariant() external view {
        uint256 allowed = handler.calls("transfer") + handler.calls("approve") + handler.calls("lock")
            + handler.calls("split") + handler.calls("native");
        uint256 blocked = handler.calls("transfer.blocked") + handler.calls("approve.blocked")
            + handler.calls("lock.blocked") + handler.calls("split.blocked") + handler.calls("native.blocked");
        assertGt(allowed, 0, "nothing was ever allowed");
        assertGt(blocked, 0, "nothing was ever blocked");
    }

    /// @notice The agent path can never loosen the policy.
    function invariant_policyUnchanged() public view {
        (uint128 perTx, uint128 perDay) = hook.tokenLimit(address(account), address(usdc));
        assertEq(perTx, PER_TX);
        assertEq(perDay, PER_DAY);
        assertEq(handler.calls("reconfigure.SUCCEEDED"), 0);
    }
}
