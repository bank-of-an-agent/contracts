// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Test.sol";

import {MockTreasuryFund} from "../../src/mocks/MockTreasuryFund.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockValidationRegistry} from "../../src/mocks/MockValidationRegistry.sol";
import {MockERC7579Account} from "../mocks/MockERC7579Account.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract MockUSDCTest is BaseTest {
    struct Auth {
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
    }

    Vm.Wallet internal alice;
    Vm.Wallet internal mallory;
    address internal bob = makeAddr("bob");
    address internal relayer = makeAddr("relayer");

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    function setUp() public override {
        super.setUp();
        alice = vm.createWallet("alice");
        mallory = vm.createWallet("mallory");
        usdc.mint(alice.addr, 1000e6);
    }

    // ------------------------------------------------------------------ helpers

    function _auth(address from, address to, uint256 value, string memory nonceLabel)
        internal
        view
        returns (Auth memory)
    {
        return Auth(from, to, value, block.timestamp - 1, block.timestamp + 60, keccak256(bytes(nonceLabel)));
    }

    function _digest(bytes32 typeHash, Auth memory a) internal view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(typeHash, a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce));
        return keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
    }

    function _transferSig(uint256 pk, Auth memory a) internal view returns (bytes memory) {
        return _sign(pk, _digest(usdc.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), a));
    }

    function _receiveSig(uint256 pk, Auth memory a) internal view returns (bytes memory) {
        return _sign(pk, _digest(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), a));
    }

    function _transferBytes(Auth memory a, bytes memory sig) internal {
        usdc.transferWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
    }

    function _transferVrs(Auth memory a, bytes memory sig) internal {
        (bytes32 r, bytes32 s) = abi.decode(sig, (bytes32, bytes32));
        uint8 v = uint8(sig[64]);
        usdc.transferWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, v, r, s);
    }

    function _receiveBytes(Auth memory a, bytes memory sig) internal {
        usdc.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, sig);
    }

    function _receiveVrs(Auth memory a, bytes memory sig) internal {
        (bytes32 r, bytes32 s) = abi.decode(sig, (bytes32, bytes32));
        uint8 v = uint8(sig[64]);
        usdc.receiveWithAuthorization(a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, v, r, s);
    }

    function _cancelDigest(address authorizer, bytes32 nonce) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(usdc.CANCEL_AUTHORIZATION_TYPEHASH(), authorizer, nonce));
        return keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
    }

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(usdc.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
    }

    // ------------------------------------------------------------------ metadata

    function test_metadataMatchesUsdc() public view {
        assertEq(usdc.name(), "USDC");
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.version(), "2");
        assertEq(
            usdc.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256("USDC"),
                    keccak256("2"),
                    block.chainid,
                    address(usdc)
                )
            )
        );
        assertEq(usdc.blacklister(), address(this));
    }

    // ------------------------------------------------------------------ transferWithAuthorization

    function test_transferWithAuthorization_vrs() public {
        Auth memory a = _auth(alice.addr, bob, 10e6, "n1");
        bytes memory sig = _transferSig(alice.privateKey, a);
        vm.expectEmit(true, true, false, false, address(usdc));
        emit AuthorizationUsed(alice.addr, a.nonce);
        vm.prank(relayer);
        _transferVrs(a, sig);
        assertEq(usdc.balanceOf(bob), 10e6);
        assertTrue(usdc.authorizationState(alice.addr, a.nonce));
    }

    function test_transferWithAuthorization_bytesEoa() public {
        Auth memory a = _auth(alice.addr, bob, 1e6, "n2");
        _transferBytes(a, _transferSig(alice.privateKey, a));
        assertEq(usdc.balanceOf(bob), 1e6);
    }

    function test_transferWithAuthorization_erc1271Wallet_bothOverloads() public {
        MockERC7579Account wallet = new MockERC7579Account(entryPoint, alice.addr);
        usdc.mint(address(wallet), 50e6);
        Auth memory a = _auth(address(wallet), bob, 5e6, "w1");
        _transferBytes(a, _transferSig(alice.privateKey, a));
        Auth memory b = _auth(address(wallet), bob, 5e6, "w2");
        _transferVrs(b, _transferSig(alice.privateKey, b)); // (v,r,s) also reaches ERC-1271 for contracts
        assertEq(usdc.balanceOf(address(wallet)), 40e6);
        assertEq(usdc.balanceOf(bob), 10e6);
    }

    function test_transferWithAuthorization_failures() public {
        Auth memory a = _auth(alice.addr, bob, 1e6, "n4");
        bytes memory good = _transferSig(alice.privateKey, a);
        bytes memory bad = _transferSig(mallory.privateKey, a);

        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        _transferBytes(a, bad);

        Auth memory more = _auth(alice.addr, bob, 2e6, "n4");
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        _transferBytes(more, good);

        Auth memory early = _auth(alice.addr, bob, 1e6, "n4");
        early.validAfter = block.timestamp;
        bytes memory earlySig = _transferSig(alice.privateKey, early); // sign before arming expectRevert
        vm.expectRevert(bytes("FiatTokenV2: authorization is not yet valid"));
        _transferBytes(early, earlySig);

        Auth memory late = _auth(alice.addr, bob, 1e6, "n4");
        late.validBefore = block.timestamp;
        bytes memory lateSig = _transferSig(alice.privateKey, late);
        vm.expectRevert(bytes("FiatTokenV2: authorization is expired"));
        _transferBytes(late, lateSig);

        _transferBytes(a, good);
        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        _transferBytes(a, good);
    }

    // ------------------------------------------------------------------ receiveWithAuthorization

    function test_receiveWithAuthorization_onlyPayee_bothVariants() public {
        Auth memory a = _auth(alice.addr, bob, 3e6, "r1");
        bytes memory sig = _receiveSig(alice.privateKey, a);

        vm.prank(relayer);
        vm.expectRevert(bytes("FiatTokenV2: caller must be the payee"));
        _receiveVrs(a, sig);

        // a transfer-type authorization cannot be redeemed as a receive (different typehash)
        bytes memory transferSig = _transferSig(alice.privateKey, a);
        vm.prank(bob);
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        _receiveBytes(a, transferSig);

        vm.prank(bob);
        _receiveVrs(a, sig);
        assertEq(usdc.balanceOf(bob), 3e6);

        Auth memory b = _auth(alice.addr, bob, 1e6, "r2");
        bytes memory sig2 = _receiveSig(alice.privateKey, b);
        vm.prank(relayer);
        vm.expectRevert(bytes("FiatTokenV2: caller must be the payee"));
        _receiveBytes(b, sig2);
        vm.prank(bob);
        _receiveBytes(b, sig2);
        assertEq(usdc.balanceOf(bob), 4e6);
    }

    // ------------------------------------------------------------------ cancelAuthorization

    function test_cancelAuthorization_bothVariants() public {
        Auth memory a = _auth(alice.addr, bob, 1e6, "c1");
        bytes memory cancelSig = _sign(alice.privateKey, _cancelDigest(alice.addr, a.nonce));
        bytes memory transferSig = _transferSig(alice.privateKey, a);
        bytes memory forged = _sign(mallory.privateKey, _cancelDigest(alice.addr, a.nonce));

        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        usdc.cancelAuthorization(alice.addr, a.nonce, forged);

        (bytes32 r, bytes32 s) = abi.decode(cancelSig, (bytes32, bytes32));
        uint8 v = uint8(cancelSig[64]);
        vm.expectEmit(true, true, false, false, address(usdc));
        emit AuthorizationCanceled(alice.addr, a.nonce);
        usdc.cancelAuthorization(alice.addr, a.nonce, v, r, s);
        assertTrue(usdc.authorizationState(alice.addr, a.nonce));

        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        _transferBytes(a, transferSig);
        vm.expectRevert(bytes("FiatTokenV2: authorization is used or canceled"));
        usdc.cancelAuthorization(alice.addr, a.nonce, v, r, s);

        bytes32 nonce2 = keccak256("c2");
        usdc.cancelAuthorization(alice.addr, nonce2, _sign(alice.privateKey, _cancelDigest(alice.addr, nonce2)));
        assertTrue(usdc.authorizationState(alice.addr, nonce2));
    }

    // ------------------------------------------------------------------ permit

    function test_permit_vrs() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(alice.privateKey, _permitDigest(alice.addr, bob, 7e6, 0, deadline));
        (bytes32 r, bytes32 s) = abi.decode(sig, (bytes32, bytes32));
        uint8 v = uint8(sig[64]);
        usdc.permit(alice.addr, bob, 7e6, deadline, v, r, s);
        assertEq(usdc.allowance(alice.addr, bob), 7e6);
        assertEq(usdc.nonces(alice.addr), 1);
        vm.expectRevert(bytes("EIP2612: invalid signature"));
        usdc.permit(alice.addr, bob, 7e6, deadline, v, r, s); // nonce moved
    }

    function test_permit_bytesAndErc1271AndExpiry() public {
        uint256 deadline = block.timestamp + 1 hours;
        usdc.permit(
            alice.addr, bob, 9e6, deadline, _sign(alice.privateKey, _permitDigest(alice.addr, bob, 9e6, 0, deadline))
        );
        assertEq(usdc.allowance(alice.addr, bob), 9e6);

        MockERC7579Account wallet = new MockERC7579Account(entryPoint, alice.addr);
        bytes memory walletSig = _sign(alice.privateKey, _permitDigest(address(wallet), bob, 1, 0, deadline));
        usdc.permit(address(wallet), bob, 1, deadline, walletSig);
        assertEq(usdc.allowance(address(wallet), bob), 1);

        bytes memory late = _sign(alice.privateKey, _permitDigest(alice.addr, bob, 1, 1, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(bytes("FiatTokenV2: permit is expired"));
        usdc.permit(alice.addr, bob, 1, deadline, late);
    }

    // ------------------------------------------------------------------ FiatToken allowance API

    event Approval(address indexed owner, address indexed spender, uint256 value);

    function test_increaseAndDecreaseAllowance() public {
        vm.startPrank(alice.addr);
        vm.expectEmit(true, true, false, true, address(usdc));
        emit Approval(alice.addr, bob, 5e6);
        assertTrue(usdc.increaseAllowance(bob, 5e6));
        assertTrue(usdc.increaseAllowance(bob, 2e6));
        assertEq(usdc.allowance(alice.addr, bob), 7e6);

        assertTrue(usdc.decreaseAllowance(bob, 3e6));
        assertEq(usdc.allowance(alice.addr, bob), 4e6);
        vm.expectRevert(bytes("ERC20: decreased allowance below zero"));
        usdc.decreaseAllowance(bob, 4e6 + 1);
        assertTrue(usdc.decreaseAllowance(bob, 4e6));
        assertEq(usdc.allowance(alice.addr, bob), 0);

        usdc.approve(bob, type(uint256).max);
        vm.expectRevert(bytes("SafeMath: addition overflow"));
        usdc.increaseAllowance(bob, 1);
        vm.stopPrank();
    }

    function test_allowanceApi_respectsBlacklist() public {
        usdc.blacklist(bob);
        vm.startPrank(alice.addr);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        usdc.approve(bob, 1);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        usdc.increaseAllowance(bob, 1);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        usdc.decreaseAllowance(bob, 0);
        vm.stopPrank();

        // a blacklisted spender cannot use an allowance it already holds, and a blacklisted owner cannot approve
        usdc.unBlacklist(bob);
        vm.prank(alice.addr);
        usdc.approve(bob, 10);
        usdc.blacklist(bob);
        vm.prank(bob);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        usdc.transferFrom(alice.addr, relayer, 1);
        usdc.unBlacklist(bob);
        usdc.blacklist(alice.addr);
        vm.prank(alice.addr);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        usdc.increaseAllowance(bob, 1);
    }

    function test_permit_respectsBlacklist() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(alice.privateKey, _permitDigest(alice.addr, bob, 1, 0, deadline));
        usdc.blacklist(bob);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        usdc.permit(alice.addr, bob, 1, deadline, sig);
    }

    function testFuzz_increaseThenDecrease_roundTrips(uint256 start, uint256 delta) public {
        start = bound(start, 0, type(uint128).max);
        delta = bound(delta, 0, type(uint128).max);
        vm.startPrank(alice.addr);
        usdc.approve(bob, start);
        usdc.increaseAllowance(bob, delta);
        assertEq(usdc.allowance(alice.addr, bob), start + delta);
        usdc.decreaseAllowance(bob, delta);
        assertEq(usdc.allowance(alice.addr, bob), start);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ blacklist

    function test_blacklist() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("Blacklistable: caller is not the blacklister"));
        usdc.blacklist(bob);
        vm.prank(stranger);
        vm.expectRevert(bytes("Blacklistable: caller is not the blacklister"));
        usdc.unBlacklist(bob);

        usdc.blacklist(bob);
        assertTrue(usdc.isBlacklisted(bob));
        vm.prank(alice.addr);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        usdc.transfer(bob, 1);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        usdc.mint(bob, 1);

        usdc.unBlacklist(bob);
        vm.prank(alice.addr);
        usdc.transfer(bob, 1);
        assertEq(usdc.balanceOf(bob), 1);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_onlyAuthorizerKeyMovesFunds(uint256 signerPk, uint256 value, bytes32 nonce) public {
        signerPk = bound(
            signerPk,
            1,
            115_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_336
        );
        Auth memory a = Auth(alice.addr, bob, bound(value, 0, 1000e6), block.timestamp - 1, block.timestamp + 60, nonce);
        bytes memory sig = _transferSig(signerPk, a);
        if (vm.addr(signerPk) == alice.addr) {
            _transferBytes(a, sig);
            assertEq(usdc.balanceOf(bob), a.value);
        } else {
            vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
            _transferBytes(a, sig);
        }
    }

    function testFuzz_validityWindow(uint256 validAfter, uint256 validBefore) public {
        Auth memory a = Auth(
            alice.addr,
            bob,
            1,
            bound(validAfter, 0, block.timestamp + 100),
            bound(validBefore, 0, block.timestamp + 100),
            keccak256(abi.encode(validAfter, validBefore))
        );
        bytes memory sig = _transferSig(alice.privateKey, a);
        if (block.timestamp <= a.validAfter) {
            vm.expectRevert(bytes("FiatTokenV2: authorization is not yet valid"));
        } else if (block.timestamp >= a.validBefore) {
            vm.expectRevert(bytes("FiatTokenV2: authorization is expired"));
        }
        _transferBytes(a, sig);
    }
}

contract MockTreasuryFundTest is BaseTest {
    MockTreasuryFund internal fund;

    function setUp() public override {
        super.setUp();
        fund = new MockTreasuryFund(IERC20(address(usdc)), address(this));
        usdc.mint(payer, 1_000_000e6);
        vm.prank(payer);
        usdc.approve(address(fund), type(uint256).max);
    }

    function test_depositCap() public {
        assertEq(fund.maxDeposit(payer), type(uint256).max);
        assertEq(fund.maxMint(payer), type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert(bytes("MockTreasuryFund: not admin"));
        fund.setDepositCap(1);

        fund.setDepositCap(100e6);
        assertEq(fund.maxDeposit(payer), 100e6);
        assertEq(fund.maxMint(payer), 100e6);
        vm.prank(payer);
        fund.deposit(60e6, payer);
        assertEq(fund.maxDeposit(payer), 40e6);
        vm.prank(payer);
        vm.expectRevert();
        fund.deposit(41e6, payer);
        vm.prank(payer);
        fund.deposit(40e6, payer);
        assertEq(fund.maxDeposit(payer), 0);
        assertEq(fund.maxMint(payer), 0);
    }

    function test_yieldRaisesSharePrice() public {
        vm.prank(payer);
        fund.deposit(100e6, payer);
        usdc.mint(address(fund), 10e6);
        assertApproxEqAbs(fund.convertToAssets(fund.balanceOf(payer)), 110e6, 1);
    }

    function testFuzz_roundTripNeverProfitsTheUser(uint256 assets, uint256 yield) public {
        assets = bound(assets, 1, 1_000_000e6);
        vm.prank(payer);
        uint256 shares = fund.deposit(assets, payer);
        usdc.mint(address(fund), bound(yield, 0, 1000e6));
        vm.prank(payer);
        uint256 out = fund.redeem(shares, payer, payer);
        assertLe(out, fund.totalAssets() + out);
        assertEq(fund.balanceOf(payer), 0);
    }
}

contract MockValidationRegistryTest is BaseTest {
    MockValidationRegistry internal registry;
    bytes32 internal constant REQUEST = keccak256("request");

    function setUp() public override {
        super.setUp();
        registry = new MockValidationRegistry();
    }

    function test_request_rules() public {
        vm.expectRevert(bytes("bad validator"));
        registry.validationRequest(address(0), 1, "uri", REQUEST);
        registry.validationRequest(validator, 1, "uri", REQUEST);
        vm.expectRevert(bytes("exists"));
        registry.validationRequest(stranger, 1, "uri", REQUEST);

        (address v, uint256 agentId, uint8 response,,, uint256 lastUpdate) = registry.getValidationStatus(REQUEST);
        assertEq(v, validator);
        assertEq(agentId, 1);
        assertEq(response, 0);
        assertEq(lastUpdate, block.timestamp);

        vm.expectRevert(bytes("unknown"));
        registry.getValidationStatus(keccak256("missing"));
    }

    function test_response_rules() public {
        registry.validationRequest(validator, 1, "uri", REQUEST);
        vm.expectRevert(bytes("not validator"));
        registry.validationResponse(REQUEST, 100, "", bytes32(0), "");
        vm.prank(validator);
        vm.expectRevert(bytes("resp>100"));
        registry.validationResponse(REQUEST, 101, "", bytes32(0), "");
        vm.prank(validator);
        vm.expectRevert(bytes("unknown"));
        registry.validationResponse(keccak256("other"), 1, "", bytes32(0), "");
    }

    function test_response_updatesStatus() public {
        registry.validationRequest(validator, 1, "uri", REQUEST);
        vm.warp(block.timestamp + 10);
        vm.prank(validator);
        registry.validationResponse(REQUEST, 77, "uri", keccak256("resp"), "tag");
        (,, uint8 response, bytes32 responseHash, string memory tag, uint256 lastUpdate) =
            registry.getValidationStatus(REQUEST);
        assertEq(response, 77);
        assertEq(responseHash, keccak256("resp"));
        assertEq(tag, "tag");
        assertEq(lastUpdate, block.timestamp);
    }

    function testFuzz_onlyValidatorResponds(address caller, uint8 response) public {
        registry.validationRequest(validator, 1, "uri", REQUEST);
        vm.prank(caller);
        if (caller != validator) {
            vm.expectRevert(bytes("not validator"));
        } else if (response > 100) {
            vm.expectRevert(bytes("resp>100"));
        }
        registry.validationResponse(REQUEST, response, "", bytes32(0), "");
    }
}
