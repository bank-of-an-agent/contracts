// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test, Vm, console2} from "forge-std/Test.sol";

/// @dev Minimal FiatToken v2.2 surface used by the spike (Base Sepolia USDC).
interface IFiatTokenV2_2 {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
    function name() external view returns (string memory);
    function version() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @dev Safe v1.4.1 surface used by the spike.
interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function domainSeparator() external view returns (bytes32);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function VERSION() external view returns (string memory);
    function nonce() external view returns (uint256);
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    function proxyCreationCode() external pure returns (bytes memory);
}

interface ICompatibilityFallbackHandler {
    function getMessageHashForSafe(address safe, bytes memory message) external view returns (bytes32);
}

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);
}

/// @title Phase 0 spike: x402 "exact" (EIP-3009) payment signed by a Safe via ERC-1271 on Base Sepolia USDC.
/// @notice Forks Base Sepolia and settles `transferWithAuthorization` where `from` is a Safe smart account whose
///         signature is validated by USDC through ERC-1271 (`CompatibilityFallbackHandler`). Results and analysis:
///         `docs/spike-x402-erc1271.md`; decision: `docs/adr/0001-x402-spend-key-float.md`.
/// @dev Runs only under `FOUNDRY_PROFILE=fork`. Skips cleanly when the RPC is unreachable.
///      Env: `BASE_SEPOLIA_RPC_URL` (default: public RPC), `BASE_SEPOLIA_FORK_BLOCK` (default: pinned block, 0 = latest).
contract X402SafeErc1271ForkTest is Test {
    // ------------------------------------------------------------------ Base Sepolia facts (verified on-chain)
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 internal constant DEFAULT_FORK_BLOCK = 47_990_000;

    IFiatTokenV2_2 internal constant USDC = IFiatTokenV2_2(0x036CbD53842c5426634e7929541eC2318f3dCF7e);
    address internal constant USDC_IMPLEMENTATION = 0xd74cc5d436923b8ba2c179b4bCA2841D8A52C5B5;
    /// @dev FiatTokenProxy (zeppelinos AdminUpgradeabilityProxy) implementation slot.
    bytes32 internal constant FIAT_TOKEN_IMPLEMENTATION_SLOT =
        0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;

    ISafeProxyFactory internal constant SAFE_PROXY_FACTORY =
        ISafeProxyFactory(0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67);
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant COMPATIBILITY_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    /// @dev keccak256("fallback_manager.handler.address")
    bytes32 internal constant SAFE_FALLBACK_HANDLER_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;

    // ------------------------------------------------------------------ EIP-712 / ERC-1271 constants
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant SAFE_DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    bytes32 internal constant SAFE_MSG_TYPEHASH = keccak256("SafeMessage(bytes message)");
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 internal constant TRANSFER_WITH_AUTHORIZATION_BYTES_SELECTOR = 0xcf092995;
    bytes4 internal constant TRANSFER_WITH_AUTHORIZATION_VRS_SELECTOR = 0xe3ee160e;
    bytes32 internal constant ERC6492_MAGIC_SUFFIX = 0x6492649264926492649264926492649264926492649264926492649264926492;

    // ------------------------------------------------------------------ revert reasons (FiatToken v2.2)
    string internal constant ERR_INVALID_SIGNATURE = "FiatTokenV2: invalid signature";
    string internal constant ERR_USED_OR_CANCELED = "FiatTokenV2: authorization is used or canceled";
    string internal constant ERR_EXPIRED = "FiatTokenV2: authorization is expired";
    string internal constant ERR_NOT_YET_VALID = "FiatTokenV2: authorization is not yet valid";
    string internal constant ERR_ECRECOVER_LENGTH = "ECRecover: invalid signature length";

    uint256 internal constant SAFE_FUNDING = 1000e6; // 1,000 USDC
    uint256 internal constant PAYMENT = 1_250_000; // 1.25 USDC, a typical x402 price point

    struct Authorization {
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
    }

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    bool internal forkAvailable;
    Vm.Wallet internal owner;
    Vm.Wallet internal coOwner1;
    Vm.Wallet internal coOwner2;
    Vm.Wallet internal stranger;
    address internal facilitator;
    address internal seller;
    address internal minter;
    address internal safe;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org"));
        uint256 forkBlock = vm.envOr("BASE_SEPOLIA_FORK_BLOCK", DEFAULT_FORK_BLOCK);
        if (forkBlock == 0) {
            try vm.createSelectFork(rpcUrl) returns (uint256) {
                forkAvailable = true;
            } catch {
                return;
            }
        } else {
            try vm.createSelectFork(rpcUrl, forkBlock) returns (uint256) {
                forkAvailable = true;
            } catch {
                return;
            }
        }
        // A reachable RPC for the wrong chain is a configuration error, not a reason to skip.
        assertEq(block.chainid, BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_RPC_URL is not Base Sepolia");

        owner = vm.createWallet("spike.safe-owner");
        coOwner1 = vm.createWallet("spike.co-owner-1");
        coOwner2 = vm.createWallet("spike.co-owner-2");
        stranger = vm.createWallet("spike.stranger");
        facilitator = makeAddr("spike.x402-facilitator");
        seller = makeAddr("spike.x402-seller");
        minter = makeAddr("spike.test-minter");

        // Fund via the real mint path: the master minter authorises a test minter, which mints to the Safe.
        // (FiatToken v2.2 packs the blacklist flag into the balance slot, so we avoid raw storage writes.)
        vm.prank(USDC.masterMinter());
        USDC.configureMinter(minter, type(uint256).max);

        safe = _deploySafe(_singleOwner(owner.addr), 1, 1);
        _mintUsdc(safe, SAFE_FUNDING);
    }

    modifier onlyFork() {
        if (!forkAvailable) vm.skip(true, "Base Sepolia RPC unreachable");
        _;
    }

    // =====================================================================================================
    // Environment facts
    // =====================================================================================================

    function test_fork_usdcIsFiatTokenV22WithBytesSignatureOverload() public onlyFork {
        address implementation = address(uint160(uint256(vm.load(address(USDC), FIAT_TOKEN_IMPLEMENTATION_SLOT))));
        assertEq(implementation, USDC_IMPLEMENTATION, "USDC implementation changed");
        assertEq(USDC.name(), "USDC");
        assertEq(USDC.version(), "2");
        assertEq(USDC.decimals(), 6);
        assertEq(
            USDC.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH, keccak256("USDC"), keccak256("2"), BASE_SEPOLIA_CHAIN_ID, address(USDC)
                )
            ),
            "EIP-712 domain is not (USDC, 2, 84532, proxy)"
        );
        assertTrue(_hasPush4(implementation.code, TRANSFER_WITH_AUTHORIZATION_BYTES_SELECTOR), "bytes overload");
        assertTrue(_hasPush4(implementation.code, TRANSFER_WITH_AUTHORIZATION_VRS_SELECTOR), "v,r,s overload");
    }

    function test_fork_safeIsV141OneOfOneWithCompatibilityFallbackHandler() public onlyFork {
        assertEq(ISafe(safe).VERSION(), "1.4.1");
        assertEq(ISafe(safe).getThreshold(), 1);
        address[] memory owners = ISafe(safe).getOwners();
        assertEq(owners.length, 1);
        assertEq(owners[0], owner.addr);
        assertEq(address(uint160(uint256(vm.load(safe, SAFE_FALLBACK_HANDLER_SLOT)))), COMPATIBILITY_FALLBACK_HANDLER);
        assertEq(USDC.balanceOf(safe), SAFE_FUNDING);
    }

    // =====================================================================================================
    // Happy paths
    // =====================================================================================================

    /// @notice The core question: a Safe-signed (ERC-1271) EIP-3009 authorization settles via the bytes overload.
    function test_fork_safeErc1271Authorization_settlesViaBytesOverload() public onlyFork {
        Authorization memory auth = _authorization(safe, seller, PAYMENT, "bytes-overload");
        bytes32 digest = _eip3009Digest(auth);
        bytes memory signature = _safeSignature(safe, digest, _singleOwnerWallet(owner));

        // The Safe itself vouches for the digest through the fallback handler (what USDC calls internally).
        assertEq(IERC1271(safe).isValidSignature(digest, signature), ERC1271_MAGIC_VALUE, "ERC-1271 rejected");
        // Our SafeMessage hash matches the handler's own computation.
        assertEq(
            ICompatibilityFallbackHandler(COMPATIBILITY_FALLBACK_HANDLER)
                .getMessageHashForSafe(safe, abi.encode(digest)),
            _safeMessageHash(safe, digest)
        );

        uint256 safeBefore = USDC.balanceOf(safe);
        uint256 sellerBefore = USDC.balanceOf(seller);
        uint256 supplyBefore = USDC.totalSupply();
        uint256 safeNonceBefore = ISafe(safe).nonce();

        vm.record();
        vm.expectEmit(true, true, false, false, address(USDC));
        emit AuthorizationUsed(safe, auth.nonce);
        uint256 gasUsed = _settleBytes(auth, signature);
        (, bytes32[] memory safeWrites) = vm.accesses(safe);

        assertEq(USDC.balanceOf(safe), safeBefore - PAYMENT, "payer debited");
        assertEq(USDC.balanceOf(seller), sellerBefore + PAYMENT, "seller credited");
        assertEq(USDC.totalSupply(), supplyBefore, "supply unchanged");
        assertEq(USDC.balanceOf(facilitator), 0, "facilitator only relays");
        assertTrue(USDC.authorizationState(safe, auth.nonce), "nonce consumed");
        // ERC-1271 validation is a STATICCALL: the account cannot record anything (no nonce bump, no spend counter).
        assertEq(safeWrites.length, 0, "Safe storage written during an EIP-3009 pull");
        assertEq(ISafe(safe).nonce(), safeNonceBefore, "Safe nonce moved");

        console2.log("[spike] Safe 1-of-1 ERC-1271, bytes overload: settled, gas", gasUsed);
    }

    /// @notice x402's reference facilitator sends 65-byte signatures to the (v,r,s) overload. FiatToken v2.2 re-packs
    ///         them and still routes contract signers through ERC-1271, so a 1-of-1 Safe works there too.
    function test_fork_safeErc1271Authorization_settlesViaVrsOverload() public onlyFork {
        Authorization memory auth = _authorization(safe, seller, PAYMENT, "vrs-overload");
        bytes memory signature = _safeSignature(safe, _eip3009Digest(auth), _singleOwnerWallet(owner));
        assertEq(signature.length, 65, "1-of-1 Safe signature is 65 bytes");

        (bytes32 r, bytes32 s, uint8 v) = _split(signature);
        vm.prank(facilitator);
        uint256 gasBefore = gasleft();
        USDC.transferWithAuthorization(
            auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce, v, r, s
        );
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(USDC.balanceOf(safe), SAFE_FUNDING - PAYMENT);
        assertEq(USDC.balanceOf(seller), PAYMENT);
        console2.log("[spike] Safe 1-of-1 ERC-1271, v,r,s overload: settled, gas", gasUsed);
    }

    /// @notice Multi-owner Safes produce concatenated signatures (65 bytes per owner): only the bytes overload fits.
    function test_fork_safe2of3Erc1271Authorization_settlesViaBytesOverload() public onlyFork {
        Vm.Wallet[] memory wallets = new Vm.Wallet[](3);
        wallets[0] = owner;
        wallets[1] = coOwner1;
        wallets[2] = coOwner2;
        address[] memory owners = new address[](3);
        for (uint256 i; i < 3; ++i) {
            owners[i] = wallets[i].addr;
        }
        address multisig = _deploySafe(owners, 2, 2);
        _mintUsdc(multisig, SAFE_FUNDING);

        Authorization memory auth = _authorization(multisig, seller, PAYMENT, "2-of-3");
        Vm.Wallet[] memory signers = new Vm.Wallet[](2);
        signers[0] = coOwner1;
        signers[1] = coOwner2;
        bytes memory signature = _safeSignature(multisig, _eip3009Digest(auth), signers);
        assertEq(signature.length, 130);

        uint256 gasUsed = _settleBytes(auth, signature);
        assertEq(USDC.balanceOf(multisig), SAFE_FUNDING - PAYMENT);
        assertEq(USDC.balanceOf(seller), PAYMENT);
        console2.log("[spike] Safe 2-of-3 ERC-1271, bytes overload: settled, gas", gasUsed);

        // A single owner's signature is below threshold.
        Authorization memory auth2 = _authorization(multisig, seller, PAYMENT, "2-of-3-underthreshold");
        bytes memory oneSig = _safeSignature(multisig, _eip3009Digest(auth2), _singleOwnerWallet(owner));
        _expectSettleRevert(auth2, oneSig, ERR_INVALID_SIGNATURE);
    }

    /// @notice Baseline for the ADR: an EOA "spend key" signs a standard EIP-3009 authorization.
    function test_fork_eoaSpendKeyBaseline_settles() public onlyFork {
        Vm.Wallet memory spendKey = vm.createWallet("spike.agent-spend-key");
        uint256 float = 25e6; // a 25 USDC float
        _mintUsdc(spendKey.addr, float);

        Authorization memory auth = _authorization(spendKey.addr, seller, PAYMENT, "eoa-spend-key");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(spendKey.privateKey, _eip3009Digest(auth));
        vm.prank(facilitator);
        uint256 gasBefore = gasleft();
        USDC.transferWithAuthorization(
            auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce, v, r, s
        );
        uint256 gasUsed = gasBefore - gasleft();
        assertEq(USDC.balanceOf(spendKey.addr), float - PAYMENT);
        assertEq(USDC.balanceOf(seller), PAYMENT);
        console2.log("[spike] EOA spend key, v,r,s overload: settled, gas", gasUsed);

        // The worst case for a leaked spend key is the float itself: it can sign away at most what it holds.
        Authorization memory drain = _authorization(spendKey.addr, stranger.addr, float, "eoa-overdraw");
        (v, r, s) = vm.sign(spendKey.privateKey, _eip3009Digest(drain));
        vm.prank(facilitator);
        vm.expectRevert(bytes("ERC20: transfer amount exceeds balance"));
        USDC.transferWithAuthorization(
            drain.from, drain.to, drain.value, drain.validAfter, drain.validBefore, drain.nonce, v, r, s
        );
    }

    // =====================================================================================================
    // Failure modes
    // =====================================================================================================

    function test_fork_replayingSameNonce_reverts() public onlyFork {
        Authorization memory auth = _authorization(safe, seller, PAYMENT, "replay");
        bytes memory signature = _safeSignature(safe, _eip3009Digest(auth), _singleOwnerWallet(owner));
        _settleBytes(auth, signature);

        _expectSettleRevert(auth, signature, ERR_USED_OR_CANCELED);
        // Same nonce with a different amount/recipient is also dead: nonces are per authorizer, not per payload.
        Authorization memory variant = _copy(auth);
        variant.value = 1;
        bytes memory variantSig = _safeSignature(safe, _eip3009Digest(variant), _singleOwnerWallet(owner));
        _expectSettleRevert(variant, variantSig, ERR_USED_OR_CANCELED);
        assertEq(USDC.balanceOf(seller), PAYMENT, "paid exactly once");
    }

    function test_fork_nonOwnerSignature_reverts() public onlyFork {
        Authorization memory auth = _authorization(safe, seller, PAYMENT, "non-owner");
        bytes memory signature = _safeSignature(safe, _eip3009Digest(auth), _singleOwnerWallet(stranger));
        _expectSettleRevert(auth, signature, ERR_INVALID_SIGNATURE);
        assertFalse(USDC.authorizationState(safe, auth.nonce));
        assertEq(USDC.balanceOf(safe), SAFE_FUNDING);
    }

    function test_fork_ownerSigningRawDigestInsteadOfSafeMessage_reverts() public onlyFork {
        // Signing the EIP-3009 digest directly (as an EOA would) is not a valid Safe signature: the Safe only
        // accepts owner signatures over SafeMessage(bytes message = abi.encode(digest)) in its own domain.
        Authorization memory auth = _authorization(safe, seller, PAYMENT, "raw-digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner.privateKey, _eip3009Digest(auth));
        _expectSettleRevert(auth, abi.encodePacked(r, s, v), ERR_INVALID_SIGNATURE);
    }

    function test_fork_expiredAuthorization_reverts() public onlyFork {
        // validBefore is exclusive: an authorization expiring "now" is already dead.
        Authorization memory auth = _authorization(safe, seller, PAYMENT, "expired-now");
        auth.validBefore = block.timestamp;
        bytes memory signature = _safeSignature(safe, _eip3009Digest(auth), _singleOwnerWallet(owner));
        _expectSettleRevert(auth, signature, ERR_EXPIRED);

        // A valid authorization held past its deadline (e.g. by a slow facilitator) dies too.
        Authorization memory late = _authorization(safe, seller, PAYMENT, "expired-later");
        bytes memory lateSig = _safeSignature(safe, _eip3009Digest(late), _singleOwnerWallet(owner));
        vm.warp(late.validBefore);
        _expectSettleRevert(late, lateSig, ERR_EXPIRED);
        assertEq(USDC.balanceOf(safe), SAFE_FUNDING);
    }

    function test_fork_notYetValidAuthorization_reverts() public onlyFork {
        Authorization memory auth = _authorization(safe, seller, PAYMENT, "not-yet-valid");
        auth.validAfter = block.timestamp; // validAfter is exclusive too
        bytes memory signature = _safeSignature(safe, _eip3009Digest(auth), _singleOwnerWallet(owner));
        _expectSettleRevert(auth, signature, ERR_NOT_YET_VALID);
    }

    function test_fork_facilitatorCannotChangeAmountOrRecipient() public onlyFork {
        Authorization memory auth = _authorization(safe, seller, PAYMENT, "tamper");
        bytes memory signature = _safeSignature(safe, _eip3009Digest(auth), _singleOwnerWallet(owner));

        Authorization memory overcharge = _copy(auth);
        overcharge.value = PAYMENT + 1;
        _expectSettleRevert(overcharge, signature, ERR_INVALID_SIGNATURE);

        Authorization memory redirect = _copy(auth);
        redirect.to = stranger.addr;
        _expectSettleRevert(redirect, signature, ERR_INVALID_SIGNATURE);

        _settleBytes(auth, signature); // the untampered authorization still works
        assertEq(USDC.balanceOf(seller), PAYMENT);
    }

    /// @notice An undeployed (counterfactual) Safe cannot pay: USDC sees an address without code, treats it as an EOA
    ///         and ecrecovers; it does not understand ERC-6492 wrappers. Deploying the Safe first fixes it.
    function test_fork_undeployedCounterfactualSafe_cannotPay_untilDeployed() public onlyFork {
        address[] memory owners = _singleOwner(owner.addr);
        uint256 saltNonce = uint256(keccak256("spike.counterfactual"));
        bytes memory initializer = _safeInitializer(owners, 1);
        address predicted = _predictSafe(initializer, saltNonce);
        assertEq(predicted.code.length, 0, "must be counterfactual");

        // Funds can be received before deployment (that part of the design holds).
        _mintUsdc(predicted, SAFE_FUNDING);
        assertEq(USDC.balanceOf(predicted), SAFE_FUNDING);

        Authorization memory auth = _authorization(predicted, seller, PAYMENT, "counterfactual");
        bytes32 digest = _eip3009Digest(auth);
        // The owner signs the SafeMessage in the would-be Safe's domain (exactly what a wallet SDK would produce).
        bytes memory signature = _safeSignature(predicted, digest, _singleOwnerWallet(owner));

        // (a) Plain signature: USDC ecrecovers it as if `from` were an EOA -> recovered address != Safe.
        _expectSettleRevert(auth, signature, ERR_INVALID_SIGNATURE);

        // (b) ERC-6492 wrapper (factory + deploy calldata + signature + magic suffix): USDC has no ERC-6492 support,
        //     so ECRecover rejects the non-65-byte blob outright.
        bytes memory factoryCalldata =
            abi.encodeCall(ISafeProxyFactory.createProxyWithNonce, (SAFE_L2_SINGLETON, initializer, saltNonce));
        bytes memory wrapped =
            abi.encodePacked(abi.encode(address(SAFE_PROXY_FACTORY), factoryCalldata, signature), ERC6492_MAGIC_SUFFIX);
        _expectSettleRevert(auth, wrapped, ERR_ECRECOVER_LENGTH);
        assertEq(USDC.balanceOf(predicted), SAFE_FUNDING, "nothing moved");

        // (c) Deploy the Safe at the predicted address; the very same plain signature now settles.
        address deployed = SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_L2_SINGLETON, initializer, saltNonce);
        assertEq(deployed, predicted);
        _settleBytes(auth, signature);
        assertEq(USDC.balanceOf(predicted), SAFE_FUNDING - PAYMENT);
        assertEq(USDC.balanceOf(seller), PAYMENT);
    }

    /// @notice The analysis point, demonstrated: ERC-1271 sees only a digest, so the account cannot tell a 1-cent
    ///         authorization from a full drain, and (being a view call) cannot count cumulative spend.
    function test_fork_erc1271SeesOnlyDigest_noAccountLevelSpendCap() public onlyFork {
        Authorization memory small = _authorization(safe, seller, 1, "cap-small");
        Authorization memory drain = _authorization(safe, stranger.addr, SAFE_FUNDING - 1, "cap-drain");
        bytes memory smallSig = _safeSignature(safe, _eip3009Digest(small), _singleOwnerWallet(owner));
        bytes memory drainSig = _safeSignature(safe, _eip3009Digest(drain), _singleOwnerWallet(owner));

        // From the account's point of view both requests are an opaque bytes32 and are equally valid.
        assertEq(IERC1271(safe).isValidSignature(_eip3009Digest(small), smallSig), ERC1271_MAGIC_VALUE);
        assertEq(IERC1271(safe).isValidSignature(_eip3009Digest(drain), drainSig), ERC1271_MAGIC_VALUE);

        _settleBytes(small, smallSig);
        _settleBytes(drain, drainSig);
        assertEq(USDC.balanceOf(safe), 0, "whole balance pulled without any account-side accounting");
    }

    // =====================================================================================================
    // Helpers
    // =====================================================================================================

    function _authorization(address from, address to, uint256 value, string memory label)
        internal
        view
        returns (Authorization memory)
    {
        return Authorization({
            from: from,
            to: to,
            value: value,
            validAfter: block.timestamp - 1, // x402 clients typically backdate validAfter slightly
            validBefore: block.timestamp + 5 minutes,
            nonce: keccak256(abi.encodePacked("spike.nonce.", label))
        });
    }

    /// @dev Memory structs alias on assignment; tampering tests need a real copy.
    function _copy(Authorization memory auth) internal pure returns (Authorization memory) {
        return Authorization(auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce);
    }

    function _eip3009Digest(Authorization memory auth) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                auth.from,
                auth.to,
                auth.value,
                auth.validAfter,
                auth.validBefore,
                auth.nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", USDC.DOMAIN_SEPARATOR(), structHash));
    }

    /// @dev SafeMessage hash the CompatibilityFallbackHandler checks for `isValidSignature(bytes32 digest, sig)`.
    ///      Computed from the address so it also works for counterfactual (undeployed) Safes.
    function _safeMessageHash(address account, bytes32 digest) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(SAFE_DOMAIN_SEPARATOR_TYPEHASH, block.chainid, account));
        bytes32 safeMessageStructHash = keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(abi.encode(digest))));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator, safeMessageStructHash));
    }

    /// @dev Concatenated ECDSA owner signatures, sorted by owner address as Safe.checkSignatures requires.
    function _safeSignature(address account, bytes32 digest, Vm.Wallet[] memory signers)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 messageHash = _safeMessageHash(account, digest);
        // insertion sort by address (tiny arrays)
        for (uint256 i = 1; i < signers.length; ++i) {
            Vm.Wallet memory key = signers[i];
            uint256 j = i;
            while (j > 0 && signers[j - 1].addr > key.addr) {
                signers[j] = signers[j - 1];
                --j;
            }
            signers[j] = key;
        }
        for (uint256 i; i < signers.length; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signers[i].privateKey, messageHash);
            signature = abi.encodePacked(signature, r, s, v);
        }
    }

    function _settleBytes(Authorization memory auth, bytes memory signature) internal returns (uint256 gasUsed) {
        vm.prank(facilitator);
        uint256 gasBefore = gasleft();
        USDC.transferWithAuthorization(
            auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce, signature
        );
        gasUsed = gasBefore - gasleft();
    }

    function _expectSettleRevert(Authorization memory auth, bytes memory signature, string memory reason) internal {
        vm.prank(facilitator);
        vm.expectRevert(bytes(reason));
        USDC.transferWithAuthorization(
            auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce, signature
        );
    }

    function _deploySafe(address[] memory owners, uint256 threshold, uint256 saltNonce) internal returns (address) {
        return
            SAFE_PROXY_FACTORY.createProxyWithNonce(SAFE_L2_SINGLETON, _safeInitializer(owners, threshold), saltNonce);
    }

    function _safeInitializer(address[] memory owners, uint256 threshold) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ISafe.setup,
            (owners, threshold, address(0), "", COMPATIBILITY_FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
    }

    function _predictSafe(bytes memory initializer, uint256 saltNonce) internal pure returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
        bytes memory deploymentData =
            abi.encodePacked(SAFE_PROXY_FACTORY.proxyCreationCode(), uint256(uint160(SAFE_L2_SINGLETON)));
        return vm.computeCreate2Address(salt, keccak256(deploymentData), address(SAFE_PROXY_FACTORY));
    }

    function _mintUsdc(address to, uint256 amount) internal {
        vm.prank(minter);
        USDC.mint(to, amount);
    }

    function _singleOwner(address account) internal pure returns (address[] memory owners) {
        owners = new address[](1);
        owners[0] = account;
    }

    function _singleOwnerWallet(Vm.Wallet memory wallet) internal pure returns (Vm.Wallet[] memory wallets) {
        wallets = new Vm.Wallet[](1);
        wallets[0] = wallet;
    }

    function _split(bytes memory signature) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(signature.length == 65, "not a 65-byte signature");
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
    }

    /// @dev True if `code` contains `PUSH4 selector` (how solc dispatches external functions).
    function _hasPush4(bytes memory code, bytes4 selector) internal pure returns (bool) {
        if (code.length < 5) return false;
        for (uint256 i; i < code.length - 4; ++i) {
            if (
                code[i] == 0x63 && code[i + 1] == selector[0] && code[i + 2] == selector[1]
                    && code[i + 3] == selector[2] && code[i + 4] == selector[3]
            ) return true;
        }
        return false;
    }
}
