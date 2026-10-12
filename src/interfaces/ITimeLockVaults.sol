// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title ITimeLockVaults
/// @notice Types, events, errors and functions of the Agent Bank time-locked savings vault registry.
interface ITimeLockVaults {
    /// @notice One vault. Funds only ever return to `account`.
    struct Vault {
        address account; // parent smart account: the only possible destination of withdrawals
        uint64 unlockAt; // after this anyone may trigger a withdrawal (to `account`)
        address owner; // principal's owner key (EOA or ERC-1271); authorises early withdrawals and owner changes
        uint96 nonce; // EIP-712 signature nonce (shared by all owner-signed actions)
        address token;
        uint256 balance;
    }

    /// @notice A vault was created for `account`.
    event VaultCreated(
        uint256 indexed id, address indexed account, address indexed owner, address token, uint64 unlockAt
    );
    /// @notice Funds were deposited.
    event Deposited(uint256 indexed id, address indexed from, uint256 amount, uint256 newBalance);
    /// @notice Funds were returned to the parent account; `early` marks an owner-signed pre-unlock withdrawal.
    event Withdrawn(uint256 indexed id, address indexed account, address indexed caller, uint256 amount, bool early);
    /// @notice The vault owner changed (signed by the previous owner).
    event OwnerChanged(uint256 indexed id, address indexed previousOwner, address indexed newOwner);

    error ZeroAddress();
    error InvalidOwner(address owner);
    error InvalidUnlockTime(uint64 unlockAt);
    error InvalidAmount();
    error VaultNotFound(uint256 id);
    error StillLocked(uint256 id, uint64 unlockAt);
    error InsufficientVaultBalance(uint256 id, uint256 requested, uint256 balance);
    error SignatureExpired(uint256 deadline);
    error InvalidSignature();

    /// @notice Creates a vault whose parent account is the caller.
    function createVault(address token, uint64 unlockAt, address owner) external returns (uint256 id);

    /// @notice Deposits `amount` into vault `id`. Anyone.
    function deposit(uint256 id, uint256 amount) external;

    /// @notice Returns `amount` to the parent account after the unlock time. Anyone.
    function withdraw(uint256 id, uint256 amount) external;

    /// @notice Returns `amount` to the parent account at any time with the owner's EIP-712 signature.
    function withdrawWithSignature(uint256 id, uint256 amount, uint256 deadline, bytes calldata signature) external;

    /// @notice Changes the vault owner with the current owner's EIP-712 signature.
    function setOwner(uint256 id, address newOwner, uint256 deadline, bytes calldata signature) external;

    /// @notice Full vault record.
    function getVault(uint256 id) external view returns (Vault memory);

    /// @notice Parent account of vault `id` (address(0) if it does not exist).
    function vaultAccount(uint256 id) external view returns (address);

    /// @notice Number of vaults ever created (ids are 1..vaultCount).
    function vaultCount() external view returns (uint256);

    /// @notice Sum of vault balances of `token`.
    function totalHeld(address token) external view returns (uint256);

    /// @notice EIP-712 digest the owner signs to authorise an early withdrawal.
    function earlyWithdrawalDigest(uint256 id, uint256 amount, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32);

    /// @notice EIP-712 digest the owner signs to hand the vault to `newOwner`.
    function setOwnerDigest(uint256 id, address newOwner, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32);
}
