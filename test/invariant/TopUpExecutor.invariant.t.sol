// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {TopUpExecutor} from "../../src/TopUpExecutor.sol";
import {MODULE_TYPE_EXECUTOR} from "../../src/interfaces/IERC7579.sol";
import {ITopUpExecutor} from "../../src/interfaces/ITopUpExecutor.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockERC7579Account} from "../mocks/MockERC7579Account.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract TopUpHandler is Test {
    TopUpExecutor public immutable topUps;
    MockERC7579Account public immutable treasury;
    MockUSDC public immutable usdc;
    address public immutable principal;
    address public immutable keeper = makeAddr("inv.keeper");
    address public immutable merchant = makeAddr("inv.merchant"); // where agents spend
    address public immutable unconfigured = makeAddr("inv.unconfigured-agent");

    address[] public agents;
    uint256 public ghostTreasuryIncome;
    uint256 public ghostOwnerWithdrawn;
    uint256 public ghostToppedUp;
    uint256 public ghostCapViolations; // must stay 0
    uint256 public ghostOverfillViolations; // must stay 0
    uint256 public ghostThresholdViolations; // must stay 0
    mapping(address agent => mapping(uint256 day => uint256)) public ghostPerDay;
    mapping(bytes32 action => uint256) public calls;

    constructor(TopUpExecutor topUps_, MockERC7579Account treasury_, MockUSDC usdc_, address[] memory agents_) {
        topUps = topUps_;
        treasury = treasury_;
        usdc = usdc_;
        principal = treasury_.owner();
        agents = agents_;
    }

    function agentSpends(uint256 agentSeed, uint256 amount) external {
        address a = agents[agentSeed % agents.length];
        uint256 balance = usdc.balanceOf(a);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(a);
        usdc.transfer(merchant, amount);
        calls["spend"]++;
    }

    function topUp(uint256 agentSeed, bool tryUnconfigured) external {
        address a = tryUnconfigured ? unconfigured : agents[agentSeed % agents.length];
        uint256 balanceBefore = usdc.balanceOf(a);
        ITopUpExecutor.TopUpRule memory r = topUps.getRule(address(treasury), a);
        vm.prank(keeper);
        try topUps.topUp(address(treasury), a) returns (uint256 amount) {
            uint256 day = block.timestamp / 1 days;
            ghostPerDay[a][day] += amount;
            ghostToppedUp += amount;
            if (topUps.spentToday(address(treasury), a) > r.maxPerDay) ghostCapViolations++;
            if (usdc.balanceOf(a) > r.refillTo) ghostOverfillViolations++;
            if (balanceBefore >= r.whenBelow) ghostThresholdViolations++;
            calls["topUp"]++;
        } catch {
            calls["topUp.nothing"]++;
        }
    }

    function treasuryIncome(uint256 amount) external {
        amount = bound(amount, 1, 1e10);
        usdc.mint(address(treasury), amount);
        ghostTreasuryIncome += amount;
    }

    function ownerWithdraws(uint256 amount) external {
        uint256 balance = usdc.balanceOf(address(treasury));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(principal);
        treasury.ownerExecute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (principal, amount)));
        ghostOwnerWithdrawn += amount;
    }

    function reconfigure(uint256 agentSeed, uint128 refillTo, uint128 whenBelow, uint128 maxPerDay) external {
        address a = agents[agentSeed % agents.length];
        refillTo = uint128(bound(refillTo, 1, 1e9));
        whenBelow = uint128(bound(whenBelow, 1, refillTo));
        maxPerDay = uint128(bound(maxPerDay, 1, 3e9));
        vm.prank(principal);
        treasury.ownerExecute(
            address(topUps),
            0,
            abi.encodeCall(TopUpExecutor.setRule, (a, address(usdc), refillTo, whenBelow, maxPerDay))
        );
        calls["reconfigure"]++;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 30 hours));
    }

    function agentsLength() external view returns (uint256) {
        return agents.length;
    }
}

contract TopUpExecutorInvariantTest is BaseTest {
    TopUpExecutor internal topUps;
    MockERC7579Account internal treasury;
    TopUpHandler internal handler;
    uint256 internal constant INITIAL_TREASURY = 1e12;

    function setUp() public override {
        super.setUp();
        topUps = new TopUpExecutor();
        treasury = new MockERC7579Account(entryPoint, makeAddr("inv.principal"));
        _fund(address(treasury), INITIAL_TREASURY);

        address[] memory agents = new address[](3);
        ITopUpExecutor.RuleInit[] memory rules = new ITopUpExecutor.RuleInit[](3);
        for (uint256 i; i < 3; ++i) {
            agents[i] = makeAddr(string.concat("inv.agent", vm.toString(i)));
            rules[i] = ITopUpExecutor.RuleInit(agents[i], ITopUpExecutor.TopUpRule(address(usdc), 100e6, 20e6, 250e6));
        }
        vm.prank(entryPoint);
        treasury.installModule(MODULE_TYPE_EXECUTOR, address(topUps), abi.encode(rules));
        handler = new TopUpHandler(topUps, treasury, usdc, agents);
        targetContract(address(handler));
    }

    /// @notice Every top-up respected the rule in force: below threshold, never above `refillTo`, never above the
    ///         daily cap.
    function invariant_rulesRespected() public view {
        assertEq(handler.ghostCapViolations(), 0);
        assertEq(handler.ghostOverfillViolations(), 0);
        assertEq(handler.ghostThresholdViolations(), 0);
    }

    /// @notice The executor's daily counter matches what actually moved today.
    function invariant_dailyCounterMatches() public view {
        uint256 day = block.timestamp / 1 days;
        for (uint256 i; i < handler.agentsLength(); ++i) {
            address a = handler.agents(i);
            assertEq(topUps.spentToday(address(treasury), a), handler.ghostPerDay(a, day));
        }
    }

    /// @notice Treasury funds only ever reach configured agents (or the owner): never the keeper or anyone else.
    function invariant_fundsOnlyToConfiguredAgents() public view {
        assertEq(usdc.balanceOf(handler.keeper()), 0);
        assertEq(usdc.balanceOf(handler.unconfigured()), 0);
        assertEq(usdc.balanceOf(address(topUps)), 0);
        assertEq(
            usdc.balanceOf(address(treasury)),
            INITIAL_TREASURY + handler.ghostTreasuryIncome() - handler.ghostOwnerWithdrawn() - handler.ghostToppedUp()
        );
    }
}
