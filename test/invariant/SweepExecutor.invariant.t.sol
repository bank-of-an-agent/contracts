// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {SweepExecutor} from "../../src/SweepExecutor.sol";
import {MODULE_TYPE_EXECUTOR} from "../../src/interfaces/IERC7579.sol";
import {ISweepExecutor} from "../../src/interfaces/ISweepExecutor.sol";
import {MockTreasuryFund} from "../../src/mocks/MockTreasuryFund.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockERC7579Account} from "../mocks/MockERC7579Account.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract SweepHandler is Test {
    SweepExecutor public immutable sweeper;
    MockTreasuryFund public immutable fund;
    MockUSDC public immutable usdc;
    MockERC7579Account public immutable treasury;
    address public immutable principal;
    address public immutable keeper = makeAddr("inv.keeper");
    address public immutable sink = makeAddr("inv.sink"); // where the owner spends

    uint256 public ghostIncome;
    uint256 public ghostSpent;
    uint256 public ghostSweepBelowFloor; // must stay 0
    uint256 public ghostSweepOverCap; // must stay 0
    uint256 public ghostRedeemOvershoot; // must stay 0
    uint256 public ghostSweeps;
    uint256 public ghostRedeems;
    mapping(bytes32 action => uint256) public calls;

    constructor(SweepExecutor sweeper_, MockTreasuryFund fund_, MockUSDC usdc_, MockERC7579Account treasury_) {
        sweeper = sweeper_;
        fund = fund_;
        usdc = usdc_;
        treasury = treasury_;
        principal = treasury_.owner();
    }

    function income(uint256 amount) external {
        amount = bound(amount, 1, 1e13);
        usdc.mint(address(treasury), amount);
        ghostIncome += amount;
        calls["income"]++;
    }

    function spend(uint256 amount) external {
        uint256 liquid = usdc.balanceOf(address(treasury));
        if (liquid == 0) return;
        amount = bound(amount, 1, liquid);
        vm.prank(principal);
        treasury.ownerExecute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (sink, amount)));
        ghostSpent += amount;
        calls["spend"]++;
    }

    function yield(uint256 bps) external {
        uint256 assets = fund.totalAssets();
        if (fund.totalSupply() == 0 || assets == 0) return; // donations to an empty fund are a separate unit test
        uint256 amount = (assets * bound(bps, 1, 200)) / 10_000; // up to +2% per step
        if (amount == 0) return;
        usdc.mint(address(fund), amount);
        calls["yield"]++;
    }

    function reconfigure(uint256 floor, uint256 threshold, uint256 bps) external {
        ISweepExecutor.SweepConfig memory c = ISweepExecutor.SweepConfig({
            fund: address(fund),
            asset: address(usdc),
            maxSavingsBps: uint16(bound(bps, 0, 10_000)),
            liquidFloor: bound(floor, 0, 1e13),
            sweepThreshold: bound(threshold, 0, 1e12)
        });
        vm.prank(principal);
        treasury.ownerExecute(address(sweeper), 0, abi.encodeCall(SweepExecutor.setConfig, (c)));
        calls["reconfigure"]++;
    }

    function sweep() external {
        ISweepExecutor.SweepConfig memory c = sweeper.getConfig(address(treasury));
        vm.prank(keeper);
        try sweeper.sweep(address(treasury)) {
            uint256 liquid = usdc.balanceOf(address(treasury));
            uint256 invested = fund.convertToAssets(fund.balanceOf(address(treasury)));
            if (liquid < c.liquidFloor) ghostSweepBelowFloor++;
            // 1 unit of ERC-4626 rounding tolerance on the invested value
            if (invested * 10_000 > (liquid + invested) * c.maxSavingsBps + 10_000) ghostSweepOverCap++;
            ghostSweeps++;
        } catch {
            calls["sweep.nothing"]++;
        }
    }

    function redeem() external {
        ISweepExecutor.SweepConfig memory c = sweeper.getConfig(address(treasury));
        uint256 sharesBefore = fund.balanceOf(address(treasury));
        vm.prank(keeper);
        try sweeper.redeem(address(treasury)) returns (uint256 shares, uint256) {
            uint256 liquid = usdc.balanceOf(address(treasury));
            // Redeems only what restores the floor (rounded up by at most one share's worth), or everything left.
            uint256 slack = fund.convertToAssets(1) + 1;
            if (shares < sharesBefore && liquid > c.liquidFloor + slack) ghostRedeemOvershoot++;
            ghostRedeems++;
        } catch {
            calls["redeem.nothing"]++;
        }
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
    }
}

contract SweepExecutorInvariantTest is BaseTest {
    SweepExecutor internal sweeper;
    MockTreasuryFund internal fund;
    MockERC7579Account internal treasury;
    SweepHandler internal handler;

    function setUp() public override {
        super.setUp();
        sweeper = new SweepExecutor();
        fund = new MockTreasuryFund(IERC20(address(usdc)));
        treasury = new MockERC7579Account(entryPoint, makeAddr("inv.principal"));
        ISweepExecutor.SweepConfig memory c = ISweepExecutor.SweepConfig({
            fund: address(fund), asset: address(usdc), maxSavingsBps: 8000, liquidFloor: 1000e6, sweepThreshold: 100e6
        });
        vm.prank(entryPoint);
        treasury.installModule(MODULE_TYPE_EXECUTOR, address(sweeper), abi.encode(c));
        handler = new SweepHandler(sweeper, fund, usdc, treasury);
        targetContract(address(handler));
    }

    /// @notice Sweeps never leave the account below its floor or above its savings cap; redemptions never overshoot.
    function invariant_rulePostconditions() public view {
        assertEq(handler.ghostSweepBelowFloor(), 0);
        assertEq(handler.ghostSweepOverCap(), 0);
        assertEq(handler.ghostRedeemOvershoot(), 0);
    }

    /// @notice Keepers can trigger the rule but never redirect funds: only the owner's own spending leaves the
    ///         account+fund perimeter, the keeper and the executor never hold anything, and no allowance lingers.
    function invariant_noRedirection() public view {
        assertEq(usdc.balanceOf(handler.keeper()), 0);
        assertEq(fund.balanceOf(handler.keeper()), 0);
        assertEq(usdc.balanceOf(address(sweeper)), 0);
        assertEq(fund.balanceOf(address(sweeper)), 0);
        assertEq(usdc.balanceOf(handler.sink()), handler.ghostSpent());
        assertEq(usdc.allowance(address(treasury), address(fund)), 0);
        // the account holds every fund share except OpenZeppelin's virtual offset (no third-party shares exist)
        assertEq(fund.totalSupply(), fund.balanceOf(address(treasury)));
    }

    /// @notice The account's total value never exceeds what came in (no value is created out of thin air) and the
    ///         fund holds exactly the assets backing the account's shares plus accrued yield.
    function invariant_valueAccounting() public view {
        uint256 liquid = usdc.balanceOf(address(treasury));
        assertEq(liquid + usdc.balanceOf(address(fund)) + usdc.balanceOf(handler.sink()), usdc.totalSupply());
        assertLe(fund.convertToAssets(fund.balanceOf(address(treasury))), usdc.balanceOf(address(fund)));
    }
}
