// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title GuardianPausable
/// @notice An inflow-only circuit breaker. The pause guardian can stop NEW money entering a contract (new escrows,
///         new streams, top-ups, vault deposits). It can never block releases, refunds, settlements, cancellations,
///         withdrawals or any other exit, and it has no power over funds already held.
/// @dev Inheriting contracts apply `whenNotPaused` only to functions that pull new funds in. Renouncing the guardian
///      (transferring to address(0)) while paused permanently retires the contract for new deposits ("sunset") while
///      every exit keeps working.
abstract contract GuardianPausable {
    address private _pauseGuardian;
    bool private _paused;

    /// @notice Emitted when the pause guardian changes (including at construction and on renounce).
    event PauseGuardianTransferred(address indexed previousGuardian, address indexed newGuardian);
    /// @notice Emitted when new deposits are paused.
    event Paused(address indexed guardian);
    /// @notice Emitted when new deposits are unpaused.
    event Unpaused(address indexed guardian);

    /// @notice Caller is not the pause guardian.
    error NotPauseGuardian(address caller);
    /// @notice New deposits are currently paused.
    error NewDepositsPaused();
    /// @notice The requested pause state is already in effect.
    error PauseStateUnchanged(bool paused);

    /// @param pauseGuardian_ Initial pause guardian; address(0) deploys without a guardian (never pausable).
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(address pauseGuardian_) {
        _pauseGuardian = pauseGuardian_;
        emit PauseGuardianTransferred(address(0), pauseGuardian_);
    }

    modifier onlyPauseGuardian() {
        // A renounced (zero) guardian means nobody, even for a hypothetical msg.sender of address(0).
        if (msg.sender != _pauseGuardian || msg.sender == address(0)) revert NotPauseGuardian(msg.sender);
        _;
    }

    /// @dev Apply ONLY to functions that bring new funds into the contract.
    modifier whenNotPaused() {
        if (_paused) revert NewDepositsPaused();
        _;
    }

    /// @notice The address allowed to pause and unpause new deposits (address(0) if none).
    function pauseGuardian() public view returns (address) {
        return _pauseGuardian;
    }

    /// @notice Whether new deposits are paused. Exits are never paused.
    function paused() public view returns (bool) {
        return _paused;
    }

    /// @notice Pauses new deposits. Only the pause guardian.
    function pause() external onlyPauseGuardian {
        if (_paused) revert PauseStateUnchanged(true);
        _paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpauses new deposits. Only the pause guardian.
    function unpause() external onlyPauseGuardian {
        if (!_paused) revert PauseStateUnchanged(false);
        _paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Hands the guardian role to `newGuardian`; address(0) renounces it forever.
    /// @param newGuardian The new pause guardian.
    // forge-lint: disable-next-line(missing-zero-check)
    function transferPauseGuardian(address newGuardian) external onlyPauseGuardian {
        address previousGuardian = _pauseGuardian;
        _pauseGuardian = newGuardian; // address(0) is a deliberate, permanent renounce
        emit PauseGuardianTransferred(previousGuardian, newGuardian);
    }
}
