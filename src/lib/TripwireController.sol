// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITripwireController} from "../interfaces/ITripwireController.sol";

/// @title TripwireController
/// @author SigIntZero
/// @custom:version v1.0
/// @custom:date 2026-03-12
/// @notice Reference implementation of the ITripwireController interface.
/// @dev Manages circuit breaker state for any number of guarded contracts. Each guarded
/// contract has a guardian (manages operators) and a set of operators (can trip/reset
/// circuit breakers). Guardians can also trip (but not reset) for emergency scenarios.
/// State is stored as simple boolean mappings for minimal gas on reads.
contract TripwireController is ITripwireController {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @dev Guardian address per guarded contract. Zero means not registered.
    mapping(address guardedContract => address) private _guardians;

    /// @dev Pending guardian for two-step guardianship transfer.
    mapping(address guardedContract => address) private _pendingGuardians;

    /// @dev Operator permissions: guardedContract => operator => authorized.
    mapping(address guardedContract => mapping(address operator => bool)) private _operators;

    /// @dev Global trip state per guarded contract.
    mapping(address guardedContract => bool) private _globalTripped;

    /// @dev Per-function trip state: guardedContract => selector => tripped.
    mapping(address guardedContract => mapping(bytes4 selector => bool)) private _functionTripped;

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /// @dev Reverts if the contract is not registered.
    modifier onlyRegistered(address guardedContract) {
        _onlyRegistered(guardedContract);
        _;
    }

    /// @dev Reverts if the caller is not the guardian.
    modifier onlyGuardian(address guardedContract) {
        _onlyGuardian(guardedContract);
        _;
    }

    /// @dev Reverts if the caller is not an operator.
    modifier onlyOperator(address guardedContract) {
        _onlyOperator(guardedContract);
        _;
    }

    /// @dev Reverts if the caller is not the guardian or an operator.
    modifier onlyGuardianOrOperator(address guardedContract) {
        _onlyGuardianOrOperator(guardedContract);
        _;
    }

    function _onlyRegistered(address guardedContract) internal view {
        if (_guardians[guardedContract] == address(0)) {
            revert NotRegistered(guardedContract);
        }
    }

    function _onlyGuardian(address guardedContract) internal view {
        if (_guardians[guardedContract] != msg.sender) {
            revert NotGuardian(msg.sender, guardedContract);
        }
    }

    function _onlyOperator(address guardedContract) internal view {
        if (!_operators[guardedContract][msg.sender]) {
            revert NotOperator(msg.sender, guardedContract);
        }
    }

    function _onlyGuardianOrOperator(address guardedContract) internal view {
        if (_guardians[guardedContract] != msg.sender && !_operators[guardedContract][msg.sender]) {
            revert NotGuardianOrOperator(msg.sender, guardedContract);
        }
    }

    // ========================================================================
    // REGISTRATION
    // ========================================================================

    /// @inheritdoc ITripwireController
    function register(address guardedContract, address guardian_) external {
        if (guardedContract == address(0) || guardian_ == address(0)) {
            revert ZeroAddress();
        }
        if (msg.sender != guardedContract) {
            revert CallerNotGuardedContract(msg.sender, guardedContract);
        }
        if (_guardians[guardedContract] != address(0)) {
            revert AlreadyRegistered(guardedContract);
        }

        _guardians[guardedContract] = guardian_;
        emit Registered(guardedContract, guardian_);
    }

    // ========================================================================
    // TRIP CONTROLS
    // ========================================================================

    /// @inheritdoc ITripwireController
    function trip(address guardedContract, bytes4 selector)
        external
        onlyRegistered(guardedContract)
        onlyGuardianOrOperator(guardedContract)
    {
        _functionTripped[guardedContract][selector] = true;
        emit FunctionTripped(guardedContract, selector, msg.sender);
    }

    /// @inheritdoc ITripwireController
    function tripGlobal(address guardedContract)
        external
        onlyRegistered(guardedContract)
        onlyGuardianOrOperator(guardedContract)
    {
        _globalTripped[guardedContract] = true;
        emit GlobalTripped(guardedContract, msg.sender);
    }

    /// @inheritdoc ITripwireController
    function reset(address guardedContract, bytes4 selector)
        external
        onlyRegistered(guardedContract)
        onlyGuardianOrOperator(guardedContract)
    {
        _functionTripped[guardedContract][selector] = false;
        emit FunctionReset(guardedContract, selector, msg.sender);
    }

    /// @inheritdoc ITripwireController
    function resetGlobal(address guardedContract)
        external
        onlyRegistered(guardedContract)
        onlyGuardianOrOperator(guardedContract)
    {
        _globalTripped[guardedContract] = false;
        emit GlobalReset(guardedContract, msg.sender);
    }

    // ========================================================================
    // BATCH OPERATIONS
    // ========================================================================

    /// @inheritdoc ITripwireController
    function tripBatch(address guardedContract, bytes4[] calldata selectors)
        external
        onlyRegistered(guardedContract)
        onlyGuardianOrOperator(guardedContract)
    {
        if (selectors.length == 0) revert EmptyBatch();
        for (uint256 i; i < selectors.length; ++i) {
            _functionTripped[guardedContract][selectors[i]] = true;
            emit FunctionTripped(guardedContract, selectors[i], msg.sender);
        }
    }

    /// @inheritdoc ITripwireController
    function resetBatch(address guardedContract, bytes4[] calldata selectors)
        external
        onlyRegistered(guardedContract)
        onlyGuardianOrOperator(guardedContract)
    {
        if (selectors.length == 0) revert EmptyBatch();
        for (uint256 i; i < selectors.length; ++i) {
            _functionTripped[guardedContract][selectors[i]] = false;
            emit FunctionReset(guardedContract, selectors[i], msg.sender);
        }
    }

    /// @inheritdoc ITripwireController
    function resetAll(address guardedContract, bytes4[] calldata selectors)
        external
        onlyRegistered(guardedContract)
        onlyGuardianOrOperator(guardedContract)
    {
        if (selectors.length == 0) revert EmptyBatch();

        _globalTripped[guardedContract] = false;
        emit GlobalReset(guardedContract, msg.sender);

        for (uint256 i; i < selectors.length; ++i) {
            _functionTripped[guardedContract][selectors[i]] = false;
            emit FunctionReset(guardedContract, selectors[i], msg.sender);
        }
    }

    // ========================================================================
    // OPERATOR MANAGEMENT
    // ========================================================================

    /// @inheritdoc ITripwireController
    function addOperator(address guardedContract, address operator)
        external
        onlyGuardian(guardedContract)
    {
        if (operator == address(0)) revert ZeroAddress();
        if (_operators[guardedContract][operator]) revert AlreadyOperator(operator, guardedContract);
        _operators[guardedContract][operator] = true;
        emit OperatorAdded(guardedContract, operator, msg.sender);
    }

    /// @inheritdoc ITripwireController
    function removeOperator(address guardedContract, address operator)
        external
        onlyGuardian(guardedContract)
    {
        if (!_operators[guardedContract][operator]) revert NotOperator(operator, guardedContract);
        _operators[guardedContract][operator] = false;
        emit OperatorRemoved(guardedContract, operator, msg.sender);
    }

    // ========================================================================
    // GUARDIAN MANAGEMENT
    // ========================================================================

    /// @inheritdoc ITripwireController
    function proposeGuardian(address guardedContract, address newGuardian)
        external
        onlyGuardian(guardedContract)
    {
        if (newGuardian == address(0)) revert ZeroAddress();
        if (newGuardian == msg.sender) revert SameGuardian(guardedContract);

        address oldPending = _pendingGuardians[guardedContract];
        if (oldPending != address(0)) {
            emit GuardianshipProposalCancelled(guardedContract, msg.sender, oldPending);
        }

        _pendingGuardians[guardedContract] = newGuardian;
        emit GuardianshipProposed(guardedContract, msg.sender, newGuardian);
    }

    /// @inheritdoc ITripwireController
    function cancelGuardianshipProposal(address guardedContract)
        external
        onlyGuardian(guardedContract)
    {
        address pending = _pendingGuardians[guardedContract];
        if (pending == address(0)) revert NoPendingGuardian(guardedContract);
        delete _pendingGuardians[guardedContract];
        emit GuardianshipProposalCancelled(guardedContract, msg.sender, pending);
    }

    /// @inheritdoc ITripwireController
    function acceptGuardianship(address guardedContract) external {
        address pending = _pendingGuardians[guardedContract];
        if (pending != msg.sender) {
            revert NotPendingGuardian(msg.sender, guardedContract);
        }

        address oldGuardian = _guardians[guardedContract];
        _guardians[guardedContract] = pending;
        delete _pendingGuardians[guardedContract];
        emit GuardianshipTransferred(guardedContract, oldGuardian, pending);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc ITripwireController
    function isRegistered(address guardedContract) external view returns (bool) {
        return _guardians[guardedContract] != address(0);
    }

    /// @inheritdoc ITripwireController
    function isTripped(address guardedContract, bytes4 selector) external view returns (bool) {
        return _globalTripped[guardedContract] || _functionTripped[guardedContract][selector];
    }

    /// @inheritdoc ITripwireController
    function isFunctionTripped(address guardedContract, bytes4 selector) external view returns (bool) {
        return _functionTripped[guardedContract][selector];
    }

    /// @inheritdoc ITripwireController
    function isGloballyTripped(address guardedContract) external view returns (bool) {
        return _globalTripped[guardedContract];
    }

    /// @inheritdoc ITripwireController
    function isOperator(address guardedContract, address account) external view returns (bool) {
        return _operators[guardedContract][account];
    }

    /// @inheritdoc ITripwireController
    function guardian(address guardedContract) external view returns (address) {
        return _guardians[guardedContract];
    }

    /// @inheritdoc ITripwireController
    function pendingGuardian(address guardedContract) external view returns (address) {
        return _pendingGuardians[guardedContract];
    }
}
