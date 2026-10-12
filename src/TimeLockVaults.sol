// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ITimeLockVaults} from "./interfaces/ITimeLockVaults.sol";
import {GuardianPausable} from "./utils/GuardianPausable.sol";
import {TokenTransfer} from "./utils/TokenTransfer.sol";

/// @title TimeLockVaults
/// @author Agent Bank
/// @notice Singleton registry of time-locked savings vaults. A smart account (the parent) creates a vault naming the
///         principal's owner key. Anyone may deposit. Withdrawals ONLY ever go back to the parent account:
///         after `unlockAt` anyone may trigger them; before that they need an EIP-712 signature from the vault owner
///         (EOA or ERC-1271 contract). Agents holding session keys on the parent account therefore cannot unlock
///         savings early, and nobody (including Agent Bank) can send vault funds anywhere else.
/// @dev Non-custodial: no admin, no upgradeability. The pause guardian can only stop new deposits.
///      Invariant: `balanceOf(this) >= totalHeld[token] == sum(vault balances)`.
///      The owner must not be the parent account itself: otherwise any key able to make the account sign ERC-1271
///      messages (e.g. a session key) could authorise early withdrawals. ERC-6492 (counterfactual) owners are not
///      supported; deploy contract owners first.
contract TimeLockVaults is ITimeLockVaults, EIP712, GuardianPausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Longest allowed lock (bounds how long a mistaken or griefing vault can freeze funds).
    uint64 public constant MAX_LOCK_DURATION = 3650 days;

    /// @notice keccak256("EarlyWithdrawal(uint256 vaultId,uint256 amount,uint256 nonce,uint256 deadline)")
    bytes32 public constant EARLY_WITHDRAWAL_TYPEHASH =
        keccak256("EarlyWithdrawal(uint256 vaultId,uint256 amount,uint256 nonce,uint256 deadline)");
    /// @notice keccak256("SetOwner(uint256 vaultId,address newOwner,uint256 nonce,uint256 deadline)")
    bytes32 public constant SET_OWNER_TYPEHASH =
        keccak256("SetOwner(uint256 vaultId,address newOwner,uint256 nonce,uint256 deadline)");

    uint256 private _vaultCount;
    mapping(uint256 id => Vault) private _vaults;

    /// @inheritdoc ITimeLockVaults
    mapping(address token => uint256) public override totalHeld;

    /// @param pauseGuardian_ Address that may pause new deposits (address(0) for none).
    constructor(address pauseGuardian_) EIP712("AgentBank TimeLockVaults", "1") GuardianPausable(pauseGuardian_) {}

    // ---------------------------------------------------------------------------------------------------------------
    // Mutating functions
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Creates an empty vault whose parent account is the caller.
    /// @param token ERC-20 token held by the vault.
    /// @param unlockAt Unix time after which anyone may withdraw to the parent (in `(now, now + MAX_LOCK_DURATION]`).
    /// @param owner Principal's owner key (EOA or ERC-1271 contract) that may sign early withdrawals and owner
    ///        changes. Must not be the caller (the parent account) or this contract.
    /// @return id The new vault id.
    function createVault(address token, uint64 unlockAt, address owner) external returns (uint256 id) {
        if (token == address(0)) revert ZeroAddress();
        if (owner == address(0) || owner == msg.sender || owner == address(this)) revert InvalidOwner(owner);
        if (unlockAt <= block.timestamp || unlockAt > block.timestamp + MAX_LOCK_DURATION) {
            revert InvalidUnlockTime(unlockAt);
        }

        id = ++_vaultCount;
        Vault storage v = _vaults[id];
        v.account = msg.sender;
        v.unlockAt = unlockAt;
        v.owner = owner;
        v.token = token;
        emit VaultCreated(id, msg.sender, owner, token, unlockAt);
    }

    /// @notice Deposits `amount` into vault `id`, pulled from the caller. Anyone may deposit for the account.
    /// @param id Vault id.
    /// @param amount Amount (> 0). Fee-on-transfer tokens revert.
    function deposit(uint256 id, uint256 amount) external nonReentrant whenNotPaused {
        Vault storage v = _existing(id);
        if (amount == 0) revert InvalidAmount();
        uint256 newBalance = v.balance + amount;
        v.balance = newBalance;
        address token = v.token;
        totalHeld[token] += amount;
        emit Deposited(id, msg.sender, amount, newBalance);

        TokenTransfer.pullExact(token, amount);
    }

    /// @notice Returns `amount` to the parent account once the vault is unlocked. Callable by anyone.
    /// @param id Vault id.
    /// @param amount Amount (> 0, <= balance).
    function withdraw(uint256 id, uint256 amount) external nonReentrant {
        Vault storage v = _existing(id);
        uint64 unlockAt = v.unlockAt;
        if (block.timestamp < unlockAt) revert StillLocked(id, unlockAt);
        _withdraw(id, v, amount, false);
    }

    /// @notice Returns `amount` to the parent account at any time, authorised by the vault owner's EIP-712 signature
    ///         over `EarlyWithdrawal(vaultId, amount, nonce, deadline)`. Callable by anyone (relayers).
    /// @param id Vault id.
    /// @param amount Amount (> 0, <= balance); must equal the signed amount.
    /// @param deadline Last valid timestamp of the signature (inclusive).
    /// @param signature Owner signature (65-byte ECDSA for EOAs, arbitrary bytes for ERC-1271 owners).
    function withdrawWithSignature(uint256 id, uint256 amount, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        Vault storage v = _existing(id);
        bytes32 structHash = keccak256(abi.encode(EARLY_WITHDRAWAL_TYPEHASH, id, amount, v.nonce, deadline));
        _useOwnerSignature(v, structHash, deadline, signature);
        _withdraw(id, v, amount, true);
    }

    /// @notice Hands the vault to `newOwner`, authorised by the current owner's EIP-712 signature over
    ///         `SetOwner(vaultId, newOwner, nonce, deadline)`. Callable by anyone (relayers).
    /// @dev Re-signing for the same owner is a cheap way to invalidate an outstanding signature (it bumps the nonce).
    /// @param id Vault id.
    /// @param newOwner New owner (non-zero, not the parent account, not this contract).
    /// @param deadline Last valid timestamp of the signature (inclusive).
    /// @param signature Current owner's signature.
    function setOwner(uint256 id, address newOwner, uint256 deadline, bytes calldata signature) external nonReentrant {
        Vault storage v = _existing(id);
        if (newOwner == address(0) || newOwner == v.account || newOwner == address(this)) {
            revert InvalidOwner(newOwner);
        }
        bytes32 structHash = keccak256(abi.encode(SET_OWNER_TYPEHASH, id, newOwner, v.nonce, deadline));
        _useOwnerSignature(v, structHash, deadline, signature);

        address previousOwner = v.owner;
        v.owner = newOwner;
        // The preceding external call is the owner's ERC-1271 check, a STATICCALL (no reentrancy into state changes).
        // forge-lint: disable-next-line(reentrancy-events)
        emit OwnerChanged(id, previousOwner, newOwner);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ITimeLockVaults
    function getVault(uint256 id) external view returns (Vault memory) {
        return _vaults[id];
    }

    /// @inheritdoc ITimeLockVaults
    function vaultAccount(uint256 id) external view returns (address) {
        return _vaults[id].account;
    }

    /// @inheritdoc ITimeLockVaults
    function vaultCount() external view returns (uint256) {
        return _vaultCount;
    }

    /// @inheritdoc ITimeLockVaults
    function earlyWithdrawalDigest(uint256 id, uint256 amount, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(EARLY_WITHDRAWAL_TYPEHASH, id, amount, nonce, deadline)));
    }

    /// @inheritdoc ITimeLockVaults
    function setOwnerDigest(uint256 id, address newOwner, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(SET_OWNER_TYPEHASH, id, newOwner, nonce, deadline)));
    }

    /// @notice EIP-712 domain separator ("AgentBank TimeLockVaults", "1", chainid, this).
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    function _existing(uint256 id) private view returns (Vault storage v) {
        v = _vaults[id];
        if (v.account == address(0)) revert VaultNotFound(id);
    }

    function _useOwnerSignature(Vault storage v, bytes32 structHash, uint256 deadline, bytes calldata signature)
        private
    {
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        if (!SignatureChecker.isValidSignatureNowCalldata(v.owner, _hashTypedDataV4(structHash), signature)) {
            revert InvalidSignature();
        }
        v.nonce += 1;
    }

    function _withdraw(uint256 id, Vault storage v, uint256 amount, bool early) private {
        uint256 balance = v.balance;
        if (amount == 0) revert InvalidAmount();
        if (amount > balance) revert InsufficientVaultBalance(id, amount, balance);

        v.balance = balance - amount;
        address token = v.token;
        address account = v.account;
        totalHeld[token] -= amount;
        // The only external call that can precede this event is the owner's ERC-1271 check (a STATICCALL).
        // forge-lint: disable-next-line(reentrancy-events)
        emit Withdrawn(id, account, msg.sender, amount, early);

        IERC20(token).safeTransfer(account, amount);
    }
}
