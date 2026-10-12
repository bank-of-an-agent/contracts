// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title MockUSDC
/// @notice TEST/ANVIL ONLY. A 6-decimal ERC-20 that mirrors the parts of Circle's FiatToken v2.2 that Agent Bank relies
///         on, so local runs behave like Base USDC:
///         - EIP-712 domain name "USDC", version "2";
///         - EIP-3009 `transferWithAuthorization` / `receiveWithAuthorization` / `cancelAuthorization`, each in the
///           `(v, r, s)` and the `bytes signature` (ERC-1271 capable, via SignatureChecker) variants;
///         - EIP-2612 `permit` in both variants;
///         - FiatToken revert strings for authorization failures (x402 facilitators match on them);
///         - a blacklist (controlled by the deployer) to exercise "USDC froze an address" liveness paths.
///         `mint` is open to anyone: it is a faucet for tests. Never deploy outside a local chain.
contract MockUSDC is ERC20, EIP712 {
    /// @notice keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;
    /// @notice keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;
    /// @notice keccak256("CancelAuthorization(address authorizer,bytes32 nonce)")
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        0x158b0a9edf7a828aad02f63cd515c68ef2f50ba807396f6d12842833a1597429;
    /// @notice keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    /// @notice Address allowed to (un)blacklist accounts (the deployer).
    address public immutable blacklister;

    mapping(address authorizer => mapping(bytes32 nonce => bool)) private _authorizationStates;
    mapping(address owner => uint256) private _permitNonces;
    mapping(address account => bool) private _blacklisted;

    /// @notice An EIP-3009 authorization was used.
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    /// @notice An EIP-3009 authorization was canceled.
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);
    /// @notice `account` was blacklisted.
    event Blacklisted(address indexed account);
    /// @notice `account` was removed from the blacklist.
    event UnBlacklisted(address indexed account);

    constructor() ERC20("USDC", "USDC") EIP712("USDC", "2") {
        blacklister = msg.sender;
    }

    // ------------------------------------------------------------------ ERC-20 / FiatToken parity

    /// @notice 6 decimals, like USDC.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice EIP-712 version string, like FiatToken ("2").
    function version() external pure returns (string memory) {
        return "2";
    }

    /// @notice EIP-712 domain separator ("USDC", "2", chainid, this).
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Test faucet: mints `amount` to `to`. Anyone may call.
    /// @param to Recipient.
    /// @param amount Amount in 6-decimal units.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Whether `account` is blacklisted.
    /// @param account Address to check.
    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    /// @notice Blacklists `account` (cannot send or receive). Blacklister only.
    /// @param account Address to freeze.
    function blacklist(address account) external {
        require(msg.sender == blacklister, "Blacklistable: caller is not the blacklister");
        _blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /// @notice Removes `account` from the blacklist. Blacklister only.
    /// @param account Address to unfreeze.
    function unBlacklist(address account) external {
        require(msg.sender == blacklister, "Blacklistable: caller is not the blacklister");
        _blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    // ------------------------------------------------------------------ EIP-3009

    /// @notice Whether `nonce` of `authorizer` was used or canceled.
    /// @param authorizer Authorizer address.
    /// @param nonce Authorization nonce.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    /// @notice Executes a transfer authorized by `from`'s signature (v, r, s variant).
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
    ) external {
        _transferWithAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            abi.encodePacked(r, s, v)
        );
    }

    /// @notice Executes a transfer authorized by `from`'s signature (bytes variant; ERC-1271 for contracts).
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external {
        _transferWithAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
    }

    /// @notice Like `transferWithAuthorization` but only the payee may submit it (v, r, s variant).
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(to == msg.sender, "FiatTokenV2: caller must be the payee");
        _transferWithAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            abi.encodePacked(r, s, v)
        );
    }

    /// @notice Like `transferWithAuthorization` but only the payee may submit it (bytes variant).
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external {
        require(to == msg.sender, "FiatTokenV2: caller must be the payee");
        _transferWithAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
    }

    /// @notice Cancels an unused authorization (v, r, s variant).
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        _cancelAuthorization(authorizer, nonce, abi.encodePacked(r, s, v));
    }

    /// @notice Cancels an unused authorization (bytes variant).
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) external {
        _cancelAuthorization(authorizer, nonce, signature);
    }

    // ------------------------------------------------------------------ EIP-2612

    /// @notice Current EIP-2612 nonce of `owner`.
    /// @param owner Token owner.
    function nonces(address owner) external view returns (uint256) {
        return _permitNonces[owner];
    }

    /// @notice EIP-2612 permit (v, r, s variant).
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        _permit(owner, spender, value, deadline, abi.encodePacked(r, s, v));
    }

    /// @notice EIP-2612 permit (bytes variant; ERC-1271 for contract owners).
    function permit(address owner, address spender, uint256 value, uint256 deadline, bytes memory signature) external {
        _permit(owner, spender, value, deadline, signature);
    }

    // ------------------------------------------------------------------ internals

    function _update(address from, address to, uint256 value) internal override {
        require(!_blacklisted[from] && !_blacklisted[to], "Blacklistable: account is blacklisted");
        super._update(from, to, value);
    }

    function _transferWithAuthorization(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) private {
        require(block.timestamp > validAfter, "FiatTokenV2: authorization is not yet valid");
        require(block.timestamp < validBefore, "FiatTokenV2: authorization is expired");
        require(!_authorizationStates[from][nonce], "FiatTokenV2: authorization is used or canceled");
        bytes32 structHash = keccak256(abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce));
        require(
            SignatureChecker.isValidSignatureNow(from, _hashTypedDataV4(structHash), signature),
            "FiatTokenV2: invalid signature"
        );
        _authorizationStates[from][nonce] = true;
        // Preceded only by the signer's ERC-1271 check (STATICCALL); same ordering as FiatToken.
        // forge-lint: disable-next-line(reentrancy-events)
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

    function _cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) private {
        require(!_authorizationStates[authorizer][nonce], "FiatTokenV2: authorization is used or canceled");
        bytes32 structHash = keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce));
        require(
            SignatureChecker.isValidSignatureNow(authorizer, _hashTypedDataV4(structHash), signature),
            "FiatTokenV2: invalid signature"
        );
        _authorizationStates[authorizer][nonce] = true;
        // Preceded only by the signer's ERC-1271 check (STATICCALL); same ordering as FiatToken.
        // forge-lint: disable-next-line(reentrancy-events)
        emit AuthorizationCanceled(authorizer, nonce);
    }

    function _permit(address owner, address spender, uint256 value, uint256 deadline, bytes memory signature) private {
        require(deadline >= block.timestamp, "FiatTokenV2: permit is expired");
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _permitNonces[owner]++, deadline));
        require(
            SignatureChecker.isValidSignatureNow(owner, _hashTypedDataV4(structHash), signature),
            "EIP2612: invalid signature"
        );
        _approve(owner, spender, value);
    }
}
