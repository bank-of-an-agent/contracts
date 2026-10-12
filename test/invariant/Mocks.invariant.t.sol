// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, Vm} from "forge-std/Test.sol";

import {MockTreasuryFund} from "../../src/mocks/MockTreasuryFund.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockValidationRegistry} from "../../src/mocks/MockValidationRegistry.sol";
import {BaseTest} from "../utils/BaseTest.sol";

// ============================================================================ MockUSDC (EIP-3009)

contract UsdcHandler is Test {
    MockUSDC public immutable usdc;
    Vm.Wallet[] internal wallets;
    address public immutable relayer = makeAddr("inv.relayer");

    uint256 public ghostMinted;
    uint256 public ghostForgedAccepted; // must stay 0
    uint256 public ghostReplayAccepted; // must stay 0
    mapping(address authorizer => mapping(bytes32 nonce => bool)) public ghostConsumed;

    constructor(MockUSDC usdc_) {
        usdc = usdc_;
        for (uint256 i; i < 3; ++i) {
            wallets.push(vm.createWallet(string.concat("inv.wallet", vm.toString(i))));
        }
    }

    function mint(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1, 1e12);
        usdc.mint(wallets[seed % wallets.length].addr, amount);
        ghostMinted += amount;
    }

    function authorizedTransfer(uint256 fromSeed, uint256 toSeed, uint256 amount, uint8 nonceSeed, bool forged)
        external
    {
        Vm.Wallet memory from = wallets[fromSeed % wallets.length];
        address to = wallets[toSeed % wallets.length].addr;
        amount = bound(amount, 0, usdc.balanceOf(from.addr));
        bytes32 nonce = bytes32(uint256(nonceSeed % 8)); // small nonce space: replays are frequent
        uint256 signerPk =
            forged ? wallets[(fromSeed % wallets.length + 1) % wallets.length].privateKey : from.privateKey;
        bytes memory signature = _signTransfer(signerPk, from.addr, to, amount, nonce);
        bool wasConsumed = ghostConsumed[from.addr][nonce];
        vm.prank(relayer);
        try usdc.transferWithAuthorization(
            from.addr, to, amount, block.timestamp - 1, block.timestamp + 60, nonce, signature
        ) {
            if (forged) ghostForgedAccepted++;
            if (wasConsumed) ghostReplayAccepted++;
            ghostConsumed[from.addr][nonce] = true;
        } catch {}
    }

    function _signTransfer(uint256 pk, address from, address to, uint256 amount, bytes32 nonce)
        private
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                usdc.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
                from,
                to,
                amount,
                block.timestamp - 1,
                block.timestamp + 60,
                nonce
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function cancel(uint256 fromSeed, uint8 nonceSeed) external {
        Vm.Wallet memory from = wallets[fromSeed % wallets.length];
        bytes32 nonce = bytes32(uint256(nonceSeed % 8));
        bytes32 structHash = keccak256(abi.encode(usdc.CANCEL_AUTHORIZATION_TYPEHASH(), from.addr, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(from.privateKey, digest);
        bool wasConsumed = ghostConsumed[from.addr][nonce];
        try usdc.cancelAuthorization(from.addr, nonce, v, r, s) {
            if (wasConsumed) ghostReplayAccepted++;
            ghostConsumed[from.addr][nonce] = true;
        } catch {}
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 1 hours));
    }

    function walletAddress(uint256 i) external view returns (address) {
        return wallets[i].addr;
    }
}

contract MockUSDCInvariantTest is BaseTest {
    UsdcHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new UsdcHandler(usdc);
        targetContract(address(handler));
    }

    /// @notice Only the authorizer's own key moves funds, every nonce is single-use, and supply is conserved.
    function invariant_eip3009Soundness() public view {
        assertEq(handler.ghostForgedAccepted(), 0);
        assertEq(handler.ghostReplayAccepted(), 0);
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += usdc.balanceOf(handler.walletAddress(i));
        }
        assertEq(sum, usdc.totalSupply());
        assertEq(sum, handler.ghostMinted());
        assertEq(usdc.balanceOf(handler.relayer()), 0);
    }
}

// ============================================================================ MockTreasuryFund

contract FundHandler is Test {
    MockTreasuryFund public immutable fund;
    MockUSDC public immutable usdc;
    address[] public holders;

    constructor(MockTreasuryFund fund_, MockUSDC usdc_) {
        fund = fund_;
        usdc = usdc_;
        for (uint256 i; i < 3; ++i) {
            address h = makeAddr(string.concat("inv.holder", vm.toString(i)));
            holders.push(h);
            vm.prank(h);
            usdc.approve(address(fund_), type(uint256).max);
        }
    }

    function deposit(uint256 seed, uint256 assets) external {
        address h = holders[seed % holders.length];
        assets = bound(assets, 1, 1e12);
        usdc.mint(h, assets);
        vm.prank(h);
        try fund.deposit(assets, h) {} catch {}
    }

    function redeem(uint256 seed, uint256 shares) external {
        address h = holders[seed % holders.length];
        uint256 balance = fund.balanceOf(h);
        if (balance == 0) return;
        vm.prank(h);
        fund.redeem(bound(shares, 1, balance), h, h);
    }

    function yield(uint256 amount) external {
        usdc.mint(address(fund), bound(amount, 1, 1e10));
    }

    function holdersLength() external view returns (uint256) {
        return holders.length;
    }
}

contract MockTreasuryFundInvariantTest is BaseTest {
    MockTreasuryFund internal fund;
    FundHandler internal handler;

    function setUp() public override {
        super.setUp();
        fund = new MockTreasuryFund(IERC20(address(usdc)));
        handler = new FundHandler(fund, usdc);
        targetContract(address(handler));
    }

    /// @notice Shares are fully accounted for and always backed by the fund's assets.
    function invariant_sharesBacked() public view {
        uint256 shares;
        for (uint256 i; i < handler.holdersLength(); ++i) {
            shares += fund.balanceOf(handler.holders(i));
        }
        assertEq(shares, fund.totalSupply());
        assertEq(fund.totalAssets(), usdc.balanceOf(address(fund)));
        assertLe(fund.convertToAssets(fund.totalSupply()), fund.totalAssets());
    }
}

// ============================================================================ MockValidationRegistry

contract RegistryHandler is Test {
    MockValidationRegistry public immutable registry;
    address[] public actors;
    bytes32[] public hashes;
    mapping(bytes32 requestHash => address) public ghostValidator;
    uint256 public ghostUnauthorizedResponses; // must stay 0

    constructor(MockValidationRegistry registry_) {
        registry = registry_;
        for (uint256 i; i < 3; ++i) {
            actors.push(makeAddr(string.concat("inv.validator", vm.toString(i))));
        }
    }

    function request(uint256 validatorSeed, uint256 hashSeed) external {
        bytes32 h = keccak256(abi.encode(hashSeed % 16));
        address v = actors[validatorSeed % actors.length];
        try registry.validationRequest(v, hashSeed, "uri", h) {
            ghostValidator[h] = v;
            hashes.push(h);
        } catch {}
    }

    function respond(uint256 callerSeed, uint256 hashSeed, uint8 response) external {
        if (hashes.length == 0) return;
        bytes32 h = hashes[hashSeed % hashes.length];
        address caller = actors[callerSeed % actors.length];
        vm.prank(caller);
        try registry.validationResponse(h, response, "", bytes32(0), "") {
            if (caller != ghostValidator[h] || response > 100) ghostUnauthorizedResponses++;
        } catch {}
    }

    function hashesLength() external view returns (uint256) {
        return hashes.length;
    }
}

contract MockValidationRegistryInvariantTest is Test {
    MockValidationRegistry internal registry;
    RegistryHandler internal handler;

    function setUp() public {
        registry = new MockValidationRegistry();
        handler = new RegistryHandler(registry);
        targetContract(address(handler));
    }

    /// @notice Only the named validator can respond, responses stay within 0..100, validators never change.
    function invariant_onlyNamedValidatorResponds() public view {
        assertEq(handler.ghostUnauthorizedResponses(), 0);
        for (uint256 i; i < handler.hashesLength(); ++i) {
            bytes32 h = handler.hashes(i);
            (address v,, uint8 response,,,) = registry.getValidationStatus(h);
            assertEq(v, handler.ghostValidator(h));
            assertLe(response, 100);
        }
    }
}
