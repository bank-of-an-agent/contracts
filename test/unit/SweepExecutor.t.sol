// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {AgentPolicyHook} from "../../src/AgentPolicyHook.sol";
import {SweepExecutor} from "../../src/SweepExecutor.sol";
import {IAgentPolicyHook} from "../../src/interfaces/IAgentPolicyHook.sol";
import {MODULE_TYPE_EXECUTOR, MODULE_TYPE_HOOK} from "../../src/interfaces/IERC7579.sol";
import {ISweepExecutor} from "../../src/interfaces/ISweepExecutor.sol";
import {MockTreasuryFund} from "../../src/mocks/MockTreasuryFund.sol";
import {
    FakeFund,
    LossyFund,
    NoPayFund,
    ReentrantFund,
    ShortMintFund,
    ShortRedeemFund,
    ZeroMintFund
} from "../mocks/MaliciousFunds.sol";
import {MockERC7579Account} from "../mocks/MockERC7579Account.sol";
import {TestToken} from "../mocks/TestTokens.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract SweepExecutorTest is BaseTest {
    SweepExecutor internal sweeper;
    MockTreasuryFund internal fund;
    MockERC7579Account internal treasury;
    address internal principal = makeAddr("principal");

    uint256 internal constant FLOOR = 1000 * USDC_UNIT;
    uint256 internal constant THRESHOLD = 100 * USDC_UNIT;
    uint16 internal constant MAX_BPS = 8000;

    function setUp() public override {
        super.setUp();
        sweeper = new SweepExecutor();
        fund = new MockTreasuryFund(IERC20(address(usdc)), address(this));
        treasury = new MockERC7579Account(entryPoint, principal);
        _install(_config(address(fund), FLOOR, THRESHOLD, MAX_BPS));
    }

    // ------------------------------------------------------------------ helpers

    function _config(address fund_, uint256 floor, uint256 threshold, uint16 bps)
        internal
        view
        returns (ISweepExecutor.SweepConfig memory)
    {
        return ISweepExecutor.SweepConfig({
            fund: fund_, asset: address(usdc), maxSavingsBps: bps, liquidFloor: floor, sweepThreshold: threshold
        });
    }

    function _install(ISweepExecutor.SweepConfig memory c) internal {
        vm.prank(entryPoint);
        treasury.installModule(MODULE_TYPE_EXECUTOR, address(sweeper), abi.encode(c));
    }

    function _setConfig(ISweepExecutor.SweepConfig memory c) internal {
        vm.prank(principal);
        treasury.ownerExecute(address(sweeper), 0, abi.encodeCall(SweepExecutor.setConfig, (c)));
    }

    function _spend(uint256 amount) internal {
        vm.prank(principal);
        treasury.ownerExecute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (stranger, amount)));
    }

    function _invested() internal view returns (uint256) {
        return fund.convertToAssets(fund.balanceOf(address(treasury)));
    }

    // ------------------------------------------------------------------ lifecycle / config

    function test_install_storesConfig() public view {
        assertTrue(sweeper.isInitialized(address(treasury)));
        assertTrue(sweeper.isModuleType(MODULE_TYPE_EXECUTOR));
        assertFalse(sweeper.isModuleType(MODULE_TYPE_HOOK));
        ISweepExecutor.SweepConfig memory c = sweeper.getConfig(address(treasury));
        assertEq(c.fund, address(fund));
        assertEq(c.asset, address(usdc));
        assertEq(c.liquidFloor, FLOOR);
        assertEq(c.sweepThreshold, THRESHOLD);
        assertEq(c.maxSavingsBps, MAX_BPS);
    }

    function test_install_requiresConfigAndOnlyOnce() public {
        MockERC7579Account other = new MockERC7579Account(entryPoint, principal);
        vm.prank(entryPoint);
        vm.expectRevert();
        other.installModule(MODULE_TYPE_EXECUTOR, address(sweeper), "");

        vm.prank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.AlreadyInitialized.selector, address(treasury)));
        sweeper.onInstall(abi.encode(_config(address(fund), 1, 1, 1)));
    }

    function test_setConfig_validation() public {
        vm.startPrank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.InvalidFund.selector, address(0)));
        sweeper.setConfig(_config(address(0), 1, 1, 1));
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.InvalidFund.selector, stranger));
        sweeper.setConfig(_config(stranger, 1, 1, 1));
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.InvalidFund.selector, address(treasury)));
        sweeper.setConfig(_config(address(treasury), 1, 1, 1));
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.InvalidFund.selector, address(sweeper)));
        sweeper.setConfig(_config(address(sweeper), 1, 1, 1));

        TestToken other = new TestToken("Other", "OTH");
        MockTreasuryFund otherFund = new MockTreasuryFund(IERC20(address(other)), address(this));
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.AssetMismatch.selector, address(other), address(usdc)));
        sweeper.setConfig(_config(address(otherFund), 1, 1, 1));
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.InvalidMaxSavingsBps.selector, 10_001));
        sweeper.setConfig(_config(address(fund), 1, 1, 10_001));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.NotInitialized.selector, stranger));
        sweeper.setConfig(_config(address(fund), 1, 1, 1));
    }

    function test_setConfig_byAccount_emits() public {
        ISweepExecutor.SweepConfig memory c = _config(address(fund), 5, 6, 7);
        vm.expectEmit(true, true, true, true, address(sweeper));
        emit ISweepExecutor.SweepConfigured(address(treasury), address(fund), address(usdc), 5, 6, 7);
        _setConfig(c);
        assertEq(sweeper.getConfig(address(treasury)).liquidFloor, 5);
    }

    function test_uninstall_deletesConfig_neverReverts() public {
        vm.expectEmit(true, false, false, false, address(sweeper));
        emit ISweepExecutor.SweepUninstalled(address(treasury));
        vm.prank(entryPoint);
        treasury.uninstallModule(MODULE_TYPE_EXECUTOR, address(sweeper), "");
        assertFalse(sweeper.isInitialized(address(treasury)));
        vm.prank(stranger);
        sweeper.onUninstall(""); // no-op
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.NotInitialized.selector, address(treasury)));
        sweeper.sweep(address(treasury));
    }

    // ------------------------------------------------------------------ sweep

    function test_sweep_subscribesExcessAboveFloor_sharesToAccount() public {
        _fund(address(treasury), 5000 * USDC_UNIT);
        uint256 expected = 4000 * USDC_UNIT; // total 5,000; 80% cap = 4,000; excess above floor = 4,000
        assertEq(sweeper.previewSweep(address(treasury)), expected);

        vm.expectCall(address(usdc), abi.encodeCall(IERC20.approve, (address(fund), expected)));
        vm.expectCall(address(fund), abi.encodeCall(IERC4626.deposit, (expected, address(treasury))));
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.approve, (address(fund), 0)));
        vm.expectEmit(true, true, true, true, address(sweeper));
        emit ISweepExecutor.Swept(address(treasury), address(fund), keeper, expected, expected);
        vm.prank(keeper);
        (uint256 assets, uint256 shares) = sweeper.sweep(address(treasury));

        assertEq(assets, expected);
        assertEq(shares, expected);
        assertEq(usdc.balanceOf(address(treasury)), FLOOR);
        assertEq(fund.balanceOf(address(treasury)), shares, "shares always go to the account");
        assertEq(fund.balanceOf(keeper), 0);
        assertEq(usdc.allowance(address(treasury), address(fund)), 0, "approval reset");
    }

    function test_sweep_respectsThresholdAndFloor() public {
        _fund(address(treasury), FLOOR + THRESHOLD - 1);
        assertEq(sweeper.previewSweep(address(treasury)), 0);
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.NothingToSweep.selector, address(treasury)));
        sweeper.sweep(address(treasury));

        _fund(address(treasury), 1); // exactly floor + threshold
        (uint256 assets,) = sweeper.sweep(address(treasury));
        assertEq(assets, THRESHOLD, "sweeps everything above the floor");
        assertEq(usdc.balanceOf(address(treasury)), FLOOR);
    }

    function test_sweep_capsShareOfFundsInSavings() public {
        _setConfig(_config(address(fund), FLOOR, THRESHOLD, 5000));
        _fund(address(treasury), 10_000 * USDC_UNIT);
        (uint256 assets,) = sweeper.sweep(address(treasury));
        assertEq(assets, 5000 * USDC_UNIT);
        // at the cap: more income does not sweep until the cap room reaches the threshold
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.NothingToSweep.selector, address(treasury)));
        sweeper.sweep(address(treasury));
        _fund(address(treasury), 1000 * USDC_UNIT); // total 11,000 → cap 5,500 → room 500
        (assets,) = sweeper.sweep(address(treasury));
        assertEq(assets, 500 * USDC_UNIT);
        assertLe(_invested() * 10_000, (usdc.balanceOf(address(treasury)) + _invested()) * 5000);
    }

    function test_sweep_zeroBps_neverSweeps() public {
        _setConfig(_config(address(fund), FLOOR, THRESHOLD, 0));
        _fund(address(treasury), 1_000_000 * USDC_UNIT);
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.NothingToSweep.selector, address(treasury)));
        sweeper.sweep(address(treasury));
    }

    function test_sweep_respectsFundMaxDeposit() public {
        fund.setDepositCap(700 * USDC_UNIT);
        _fund(address(treasury), 5000 * USDC_UNIT);
        (uint256 assets,) = sweeper.sweep(address(treasury));
        assertEq(assets, 700 * USDC_UNIT);
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.NothingToSweep.selector, address(treasury)));
        sweeper.sweep(address(treasury));
    }

    function test_sweep_requiresInstalledExecutorOnAccount() public {
        MockERC7579Account rogue = new MockERC7579Account(entryPoint, principal);
        _fund(address(rogue), 5000 * USDC_UNIT);
        // config exists in the module (account called onInstall itself) but the account never enabled it
        vm.prank(principal);
        rogue.ownerExecute(
            address(sweeper),
            0,
            abi.encodeCall(SweepExecutor.onInstall, (abi.encode(_config(address(fund), FLOOR, 0, MAX_BPS))))
        );
        vm.expectRevert(abi.encodeWithSelector(MockERC7579Account.Unauthorized.selector, address(sweeper)));
        sweeper.sweep(address(rogue));
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.NotInitialized.selector, stranger));
        sweeper.sweep(stranger);
    }

    function test_sweep_rejectsFundThatShortMints() public {
        ShortMintFund bad = new ShortMintFund(IERC20(address(usdc)));
        _setConfig(_config(address(bad), FLOOR, THRESHOLD, MAX_BPS));
        _fund(address(treasury), 5000 * USDC_UNIT);
        vm.expectRevert(
            abi.encodeWithSelector(ISweepExecutor.UnexpectedSharesMinted.selector, 4000 * USDC_UNIT, 2000 * USDC_UNIT)
        );
        sweeper.sweep(address(treasury));
    }

    /// @notice Donation/inflation setup: an attacker inflates the share price of an empty fund so a sweep would mint
    ///         shares worth far less than the assets paid. The sweep refuses instead of losing value.
    function test_sweep_refusesInflatedEmptyFund() public {
        MockTreasuryFund fresh = new MockTreasuryFund(IERC20(address(usdc)), address(this));
        _setConfig(_config(address(fresh), FLOOR, THRESHOLD, MAX_BPS));
        address attacker = makeAddr("attacker");
        _fund(attacker, 1500 * USDC_UNIT + 1);
        vm.startPrank(attacker);
        usdc.approve(address(fresh), 1);
        fresh.deposit(1, attacker); // 1 share
        usdc.transfer(address(fresh), 1500 * USDC_UNIT); // donation: 1 share is now worth ~1,500 USDC
        vm.stopPrank();

        _fund(address(treasury), 5000 * USDC_UNIT);
        uint256 assets = sweeper.previewSweep(address(treasury));
        assertGt(assets, 0);
        vm.expectRevert();
        sweeper.sweep(address(treasury));
        (bool ok, bytes memory ret) = address(sweeper).call(abi.encodeCall(SweepExecutor.sweep, (address(treasury))));
        assertFalse(ok);
        assertEq(bytes4(ret), ISweepExecutor.SubscriptionLossTooHigh.selector);
    }

    function test_sweep_rejectsFundThatMintsNothing() public {
        ZeroMintFund bad = new ZeroMintFund(IERC20(address(usdc)));
        _setConfig(_config(address(bad), FLOOR, THRESHOLD, MAX_BPS));
        _fund(address(treasury), 5000 * USDC_UNIT);
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.UnexpectedSharesMinted.selector, 4000 * USDC_UNIT, 0));
        sweeper.sweep(address(treasury));
    }

    function test_redeem_rejectsFundThatPaysNothing() public {
        NoPayFund bad = new NoPayFund(IERC20(address(usdc)));
        _setConfig(_config(address(bad), FLOOR, THRESHOLD, MAX_BPS));
        _fund(address(treasury), 5000 * USDC_UNIT);
        sweeper.sweep(address(treasury));
        _spend(FLOOR);
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.UnexpectedAssetsReceived.selector, 1000 * USDC_UNIT, 0));
        sweeper.redeem(address(treasury));
    }

    function test_redeem_worthlessSharesAreNotRedeemed() public {
        LossyFund lossy = new LossyFund(IERC20(address(usdc)));
        _setConfig(_config(address(lossy), FLOOR, THRESHOLD, MAX_BPS));
        _fund(address(treasury), 5000 * USDC_UNIT);
        sweeper.sweep(address(treasury));
        lossy.loseEverything();
        _spend(FLOOR);
        assertEq(sweeper.previewRedeem(address(treasury)), 0);
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.NothingToRedeem.selector, address(treasury)));
        sweeper.redeem(address(treasury));
    }

    function test_sweep_nonErc4626FundReverts() public {
        FakeFund fake = new FakeFund(address(usdc));
        _setConfig(_config(address(fake), FLOOR, THRESHOLD, MAX_BPS));
        _fund(address(treasury), 5000 * USDC_UNIT);
        vm.expectRevert();
        sweeper.sweep(address(treasury));
    }

    function test_sweep_reentrancyBlocked() public {
        ReentrantFund reentrant = new ReentrantFund(IERC20(address(usdc)));
        _setConfig(_config(address(reentrant), FLOOR, THRESHOLD, MAX_BPS));
        _fund(address(treasury), 5000 * USDC_UNIT);
        reentrant.setCallback(address(sweeper), abi.encodeCall(SweepExecutor.sweep, (address(treasury))));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        sweeper.sweep(address(treasury));
    }

    // ------------------------------------------------------------------ redeem

    function test_redeem_refillsFloor() public {
        _fund(address(treasury), 5000 * USDC_UNIT);
        sweeper.sweep(address(treasury));
        _spend(800 * USDC_UNIT); // liquid 200 < floor 1,000

        uint256 expectedShares = fund.previewWithdraw(800 * USDC_UNIT);
        assertEq(sweeper.previewRedeem(address(treasury)), expectedShares);
        vm.expectCall(
            address(fund), abi.encodeCall(IERC4626.redeem, (expectedShares, address(treasury), address(treasury)))
        );
        vm.expectEmit(true, true, true, true, address(sweeper));
        emit ISweepExecutor.Redeemed(address(treasury), address(fund), keeper, expectedShares, 800 * USDC_UNIT);
        vm.prank(keeper);
        (uint256 shares, uint256 assets) = sweeper.redeem(address(treasury));
        assertEq(shares, expectedShares);
        assertEq(assets, 800 * USDC_UNIT);
        assertEq(usdc.balanceOf(address(treasury)), FLOOR);
        assertEq(usdc.balanceOf(keeper), 0);
    }

    function test_redeem_onlyWhenFloorBreached() public {
        _fund(address(treasury), 5000 * USDC_UNIT);
        sweeper.sweep(address(treasury));
        assertEq(sweeper.previewRedeem(address(treasury)), 0);
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.NothingToRedeem.selector, address(treasury)));
        sweeper.redeem(address(treasury));
    }

    function test_redeem_partialWhenSavingsInsufficient() public {
        _fund(address(treasury), FLOOR + 300 * USDC_UNIT);
        sweeper.sweep(address(treasury)); // 300 in the fund (cap allows), liquid = floor
        _spend(FLOOR); // liquid 0, shortfall 1,000, only 300 saved
        (uint256 shares, uint256 assets) = sweeper.redeem(address(treasury));
        assertEq(shares, 300 * USDC_UNIT);
        assertEq(assets, 300 * USDC_UNIT);
        assertEq(fund.balanceOf(address(treasury)), 0);
        vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.NothingToRedeem.selector, address(treasury)));
        sweeper.redeem(address(treasury));
    }

    function test_redeem_withYieldNeedsFewerShares() public {
        _fund(address(treasury), 5000 * USDC_UNIT);
        (, uint256 shares) = sweeper.sweep(address(treasury));
        usdc.mint(address(fund), 4000 * USDC_UNIT); // the fund doubles in value
        _spend(500 * USDC_UNIT);
        (uint256 redeemed, uint256 assets) = sweeper.redeem(address(treasury));
        assertApproxEqAbs(redeemed, 250 * USDC_UNIT, 1);
        assertGe(assets, 500 * USDC_UNIT);
        assertEq(fund.balanceOf(address(treasury)), shares - redeemed);
    }

    function test_redeem_rejectsFundThatShortPays() public {
        ShortRedeemFund bad = new ShortRedeemFund(IERC20(address(usdc)));
        _setConfig(_config(address(bad), FLOOR, THRESHOLD, MAX_BPS));
        _fund(address(treasury), 5000 * USDC_UNIT);
        sweeper.sweep(address(treasury));
        _spend(FLOOR);
        vm.expectRevert(
            abi.encodeWithSelector(ISweepExecutor.UnexpectedAssetsReceived.selector, 1000 * USDC_UNIT, 500 * USDC_UNIT)
        );
        sweeper.redeem(address(treasury));
    }

    function test_redeem_reentrancyBlocked() public {
        ReentrantFund reentrant = new ReentrantFund(IERC20(address(usdc)));
        _setConfig(_config(address(reentrant), FLOOR, THRESHOLD, MAX_BPS));
        _fund(address(treasury), 5000 * USDC_UNIT);
        sweeper.sweep(address(treasury));
        _spend(FLOOR);
        reentrant.setCallback(address(sweeper), abi.encodeCall(SweepExecutor.redeem, (address(treasury))));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        sweeper.redeem(address(treasury));
    }

    function test_previews_zeroWhenUninstalled() public view {
        assertEq(sweeper.previewSweep(stranger), 0);
        assertEq(sweeper.previewRedeem(stranger), 0);
    }

    // ------------------------------------------------------------------ interaction with the policy hook

    function test_withPolicyHook_fundMustBeAllowlisted_andSweepsAreCapped() public {
        AgentPolicyHook hook = new AgentPolicyHook();
        IAgentPolicyHook.PolicyConfig memory c;
        c.tokenLimits = new IAgentPolicyHook.TokenLimitConfig[](1);
        c.tokenLimits[0] =
            IAgentPolicyHook.TokenLimitConfig(address(usdc), uint128(2000 * USDC_UNIT), uint128(3000 * USDC_UNIT));
        vm.prank(entryPoint);
        treasury.installModule(MODULE_TYPE_HOOK, address(hook), abi.encode(c));
        _fund(address(treasury), 5000 * USDC_UNIT);

        vm.expectRevert(abi.encodeWithSelector(IAgentPolicyHook.SpenderNotAllowed.selector, address(fund)));
        sweeper.sweep(address(treasury));

        vm.prank(principal);
        treasury.ownerExecute(
            address(hook),
            0,
            abi.encodeCall(AgentPolicyHook.setContract, (address(fund), IAgentPolicyHook.ContractKind.Generic))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentPolicyHook.PerTxLimitExceeded.selector, address(usdc), 4000 * USDC_UNIT, 2000 * USDC_UNIT
            )
        );
        sweeper.sweep(address(treasury));

        _setConfig(_config(address(fund), 3000 * USDC_UNIT, THRESHOLD, MAX_BPS));
        (uint256 assets,) = sweeper.sweep(address(treasury));
        assertEq(assets, 2000 * USDC_UNIT);
        assertEq(hook.spentToday(address(treasury), address(usdc)), 2000 * USDC_UNIT);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_sweep_postconditions(uint256 liquid, uint256 floor, uint256 threshold, uint16 bps, uint256 yield)
        public
    {
        liquid = bound(liquid, 0, 1e15);
        floor = bound(floor, 0, 1e15);
        threshold = bound(threshold, 0, 1e13);
        bps = uint16(bound(bps, 0, 10_000));
        _setConfig(_config(address(fund), floor, threshold, bps));
        _fund(address(treasury), liquid);
        usdc.mint(address(fund), bound(yield, 0, 1e12)); // donation/yield before anyone invested

        uint256 totalBefore = usdc.balanceOf(address(treasury)) + _invested();
        uint256 preview = sweeper.previewSweep(address(treasury));
        if (preview == 0) {
            vm.expectRevert(abi.encodeWithSelector(ISweepExecutor.NothingToSweep.selector, address(treasury)));
            sweeper.sweep(address(treasury));
            return;
        }
        (bool ok, bytes memory ret) = address(sweeper).call(abi.encodeCall(SweepExecutor.sweep, (address(treasury))));
        if (!ok) {
            // Only the donated-empty-fund setup may refuse a sweep, and only for excessive rounding loss.
            assertEq(bytes4(ret), ISweepExecutor.SubscriptionLossTooHigh.selector);
            assertEq(fund.totalSupply(), 0);
            assertGt(usdc.balanceOf(address(fund)), 0);
            return;
        }
        (uint256 assets, uint256 shares) = abi.decode(ret, (uint256, uint256));
        assertEq(assets, preview);
        assertGt(shares, 0);
        uint256 liquidAfter = usdc.balanceOf(address(treasury));
        assertGe(liquidAfter, floor, "never sweeps below the floor");
        assertGe(assets, threshold > 0 ? 1 : 0);
        // invested value stays within the cap (allow 1 unit of ERC-4626 rounding)
        assertLe(_invested() * 10_000, (liquidAfter + _invested()) * bps + 10_000);
        // value is conserved up to the bounded rounding loss
        assertGe((liquidAfter + _invested()) * 10_000, totalBefore * 10_000 - assets * 10 - 10_000);
        assertLe(liquidAfter + _invested(), totalBefore + 1);
    }

    function testFuzz_redeem_postconditions(uint256 saved, uint256 spend, uint256 floor) public {
        floor = bound(floor, 1, 1e13);
        saved = bound(saved, 1, 1e13);
        _setConfig(_config(address(fund), floor, 0, 10_000));
        _fund(address(treasury), floor + saved);
        sweeper.sweep(address(treasury)); // invests `saved`, liquid = floor
        spend = bound(spend, 1, floor);
        _spend(spend); // liquid = floor - spend
        uint256 sharesBefore = fund.balanceOf(address(treasury));
        (uint256 shares, uint256 assets) = sweeper.redeem(address(treasury));
        assertLe(shares, sharesBefore);
        uint256 liquidAfter = usdc.balanceOf(address(treasury));
        if (shares == sharesBefore) {
            assertLe(liquidAfter, floor + 1);
        } else {
            assertGe(liquidAfter, floor, "refilled to the floor");
            assertLe(liquidAfter, floor + 1, "without over-redeeming beyond rounding");
        }
        assertEq(assets, liquidAfter - (floor - spend));
    }
}
