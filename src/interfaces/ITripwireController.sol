// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITripwireController
/// @author SigIntZero
/// @custom:version v1.0
/// @custom:date 2026-03-12
/// @notice Standardized circuit breaker controller for smart contract security.
/// @dev This interface defines the canonical way for an external controller to manage
/// per-function and global pause states on guarded contracts. It is designed for
/// EIP submission as an application-level standard.
///
/// The controller operates on a registration model:
///   1. A guarded contract registers itself with a guardian address via register().
///   2. The guardian manages operator addresses.
///   3. Operators (or the guardian, for trips only) can trip (pause) and reset (unpause) circuit breakers.
///
/// Two granularity levels are supported:
///   - Function-level: trip a specific function selector on a guarded contract.
///   - Global: trip all guarded functions on a contract at once.
interface ITripwireController {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a new contract is registered with the controller.
    /// @param guardedContract The address of the contract being guarded.
    /// @param guardian The address designated as the guardian.
    event Registered(address indexed guardedContract, address indexed guardian);

    /// @notice Emitted when a specific function's circuit breaker is tripped.
    /// @param guardedContract The address of the guarded contract.
    /// @param selector The function selector that was tripped.
    /// @param triggeredBy The address that triggered the trip.
    event FunctionTripped(address indexed guardedContract, bytes4 indexed selector, address indexed triggeredBy);

    /// @notice Emitted when a specific function's circuit breaker is reset.
    /// @param guardedContract The address of the guarded contract.
    /// @param selector The function selector that was reset.
    /// @param operator The operator who triggered the reset.
    event FunctionReset(address indexed guardedContract, bytes4 indexed selector, address indexed operator);

    /// @notice Emitted when a contract's global circuit breaker is tripped.
    /// @param guardedContract The address of the guarded contract.
    /// @param triggeredBy The address that triggered the trip.
    event GlobalTripped(address indexed guardedContract, address indexed triggeredBy);

    /// @notice Emitted when a contract's global circuit breaker is reset.
    /// @param guardedContract The address of the guarded contract.
    /// @param operator The operator who triggered the reset.
    event GlobalReset(address indexed guardedContract, address indexed operator);

    /// @notice Emitted when an operator is added for a guarded contract.
    /// @param guardedContract The address of the guarded contract.
    /// @param operator The operator address being added.
    /// @param guardian The guardian who added the operator.
    event OperatorAdded(address indexed guardedContract, address indexed operator, address indexed guardian);

    /// @notice Emitted when an operator is removed from a guarded contract.
    /// @param guardedContract The address of the guarded contract.
    /// @param operator The operator address being removed.
    /// @param guardian The guardian who removed the operator.
    event OperatorRemoved(address indexed guardedContract, address indexed operator, address indexed guardian);

    /// @notice Emitted when a guardian proposes a new guardian for a contract.
    /// @param guardedContract The address of the guarded contract.
    /// @param currentGuardian The current guardian who proposed the transfer.
    /// @param proposedGuardian The address proposed as the new guardian.
    event GuardianshipProposed(
        address indexed guardedContract, address indexed currentGuardian, address indexed proposedGuardian
    );

    /// @notice Emitted when a pending guardianship proposal is cancelled.
    /// @param guardedContract The address of the guarded contract.
    /// @param guardian The current guardian who cancelled the proposal.
    /// @param cancelledGuardian The address whose proposal was cancelled.
    event GuardianshipProposalCancelled(
        address indexed guardedContract, address indexed guardian, address indexed cancelledGuardian
    );

    /// @notice Emitted when guardianship of a contract is transferred via acceptance.
    /// @param guardedContract The address of the guarded contract.
    /// @param oldGuardian The previous guardian address.
    /// @param newGuardian The new guardian address.
    event GuardianshipTransferred(
        address indexed guardedContract, address indexed oldGuardian, address indexed newGuardian
    );

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice The caller is not the guardian of the specified contract.
    /// @param caller The address that attempted the operation.
    /// @param guardedContract The guarded contract in question.
    error NotGuardian(address caller, address guardedContract);

    /// @notice The caller is not an operator for the specified contract.
    /// @param caller The address that attempted the operation.
    /// @param guardedContract The guarded contract in question.
    error NotOperator(address caller, address guardedContract);

    /// @notice The caller is not the guardian or an operator for the specified contract.
    /// @param caller The address that attempted the operation.
    /// @param guardedContract The guarded contract in question.
    error NotGuardianOrOperator(address caller, address guardedContract);

    /// @notice The contract is already registered.
    /// @param guardedContract The contract that is already registered.
    error AlreadyRegistered(address guardedContract);

    /// @notice The contract is not registered.
    /// @param guardedContract The contract that is not registered.
    error NotRegistered(address guardedContract);

    /// @notice A zero address was provided where a non-zero address is required.
    error ZeroAddress();

    /// @notice The address is already an operator for the specified contract.
    /// @param operator The address that is already an operator.
    /// @param guardedContract The guarded contract in question.
    error AlreadyOperator(address operator, address guardedContract);

    /// @notice An empty selectors array was provided to a batch operation.
    error EmptyBatch();

    /// @notice The caller is not the pending guardian for the specified contract.
    /// @param caller The address that attempted the operation.
    /// @param guardedContract The guarded contract in question.
    error NotPendingGuardian(address caller, address guardedContract);

    /// @notice There is no pending guardianship proposal to cancel.
    /// @param guardedContract The guarded contract in question.
    error NoPendingGuardian(address guardedContract);

    /// @notice The caller is not the guarded contract itself.
    /// @param caller The address that attempted registration.
    /// @param guardedContract The guarded contract that should have been the caller.
    error CallerNotGuardedContract(address caller, address guardedContract);

    /// @notice The proposed guardian is already the current guardian.
    /// @param guardedContract The guarded contract in question.
    error SameGuardian(address guardedContract);

    // ========================================================================
    // REGISTRATION
    // ========================================================================

    /// @notice Register a contract with the controller.
    /// @dev Can only be called once per contract. Must be called by the guarded contract
    /// itself (msg.sender == guardedContract) to prevent frontrunning registration hijacks.
    /// The guardian becomes the sole authority for operator management on this contract.
    /// @param guardedContract The address of the contract to guard. Must equal msg.sender.
    /// @param guardian The address that will manage operators for this contract.
    function register(address guardedContract, address guardian) external;

    // ========================================================================
    // TRIP CONTROLS
    // ========================================================================

    /// @notice Trip the circuit breaker for a specific function.
    /// @dev Callable by an operator OR the guardian of the given guarded contract.
    /// Guardian access enables emergency trips when operators are unavailable.
    /// @param guardedContract The address of the guarded contract.
    /// @param selector The 4-byte function selector to trip.
    function trip(address guardedContract, bytes4 selector) external;

    /// @notice Trip the global circuit breaker for a contract.
    /// @dev Callable by an operator OR the guardian of the given guarded contract.
    /// Affects all functions using the `whenNotTripped` or `whenNotGloballyTripped` modifier.
    /// @param guardedContract The address of the guarded contract.
    function tripGlobal(address guardedContract) external;

    /// @notice Reset the circuit breaker for a specific function.
    /// @dev Callable by an operator OR the guardian of the given guarded contract.
    /// @param guardedContract The address of the guarded contract.
    /// @param selector The 4-byte function selector to reset.
    function reset(address guardedContract, bytes4 selector) external;

    /// @notice Reset the global circuit breaker for a contract.
    /// @dev Callable by an operator OR the guardian of the given guarded contract.
    /// Does NOT clear per-function trips. Use resetAll() to clear both.
    /// @param guardedContract The address of the guarded contract.
    function resetGlobal(address guardedContract) external;

    // ========================================================================
    // BATCH OPERATIONS
    // ========================================================================

    /// @notice Trip circuit breakers for multiple functions in a single call.
    /// @dev Callable by an operator OR the guardian of the given guarded contract.
    /// Reverts if the selectors array is empty.
    /// @param guardedContract The address of the guarded contract.
    /// @param selectors The 4-byte function selectors to trip. Must not be empty.
    function tripBatch(address guardedContract, bytes4[] calldata selectors) external;

    /// @notice Reset circuit breakers for multiple functions in a single call.
    /// @dev Callable by an operator OR the guardian of the given guarded contract.
    /// Reverts if the selectors array is empty.
    /// @param guardedContract The address of the guarded contract.
    /// @param selectors The 4-byte function selectors to reset. Must not be empty.
    function resetBatch(address guardedContract, bytes4[] calldata selectors) external;

    /// @notice Atomically reset the global circuit breaker AND specified function-level breakers.
    /// @dev Callable by an operator OR the guardian of the given guarded contract.
    /// This is the recommended way to fully restore a contract after an incident.
    /// Reverts if the selectors array is empty.
    /// @param guardedContract The address of the guarded contract.
    /// @param selectors The 4-byte function selectors to reset alongside the global flag. Must not be empty.
    function resetAll(address guardedContract, bytes4[] calldata selectors) external;

    // ========================================================================
    // OPERATOR MANAGEMENT
    // ========================================================================

    /// @notice Add an operator for a guarded contract.
    /// @dev Only callable by the guardian of the contract. Reverts if the address
    /// is already an operator.
    /// @param guardedContract The address of the guarded contract.
    /// @param operator The address to grant operator permissions to.
    function addOperator(address guardedContract, address operator) external;

    /// @notice Remove an operator from a guarded contract.
    /// @dev Only callable by the guardian of the contract. Reverts if the address
    /// is not currently an operator.
    /// @param guardedContract The address of the guarded contract.
    /// @param operator The address to revoke operator permissions from.
    function removeOperator(address guardedContract, address operator) external;

    // ========================================================================
    // GUARDIAN MANAGEMENT
    // ========================================================================

    /// @notice Propose a new guardian for a guarded contract (step 1 of 2).
    /// @dev Only callable by the current guardian. The proposed guardian must call
    /// acceptGuardianship() to complete the transfer. If a previous proposal is pending,
    /// it is cancelled and a GuardianshipProposalCancelled event is emitted before the
    /// new proposal. Reverts if newGuardian is the current guardian.
    /// @param guardedContract The address of the guarded contract.
    /// @param newGuardian The address proposed as the new guardian. Must not be the current guardian.
    function proposeGuardian(address guardedContract, address newGuardian) external;

    /// @notice Cancel a pending guardianship proposal.
    /// @dev Only callable by the current guardian. Reverts if no proposal is pending.
    /// @param guardedContract The address of the guarded contract.
    function cancelGuardianshipProposal(address guardedContract) external;

    /// @notice Accept guardianship of a guarded contract (step 2 of 2).
    /// @dev Only callable by the address previously proposed via proposeGuardian().
    /// WARNING: Existing operator permissions persist through guardianship transfers.
    /// The new guardian inherits all operators added by the previous guardian. New guardians
    /// MUST audit the operator set via OperatorAdded/OperatorRemoved event logs and remove
    /// any untrusted operators.
    /// @param guardedContract The address of the guarded contract.
    function acceptGuardianship(address guardedContract) external;

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Check if a contract is registered with this controller.
    /// @param guardedContract The address to check.
    /// @return True if the contract is registered.
    function isRegistered(address guardedContract) external view returns (bool);

    /// @notice Check if a function is effectively tripped (function-level OR global).
    /// @dev This is the primary query: "will this function revert right now?" It mirrors
    /// the check performed by the `whenNotTripped` modifier.
    /// @param guardedContract The address of the guarded contract.
    /// @param selector The 4-byte function selector to check.
    /// @return True if the function would revert due to any trip condition.
    function isTripped(address guardedContract, bytes4 selector) external view returns (bool);

    /// @notice Check if a specific function is tripped at the function level only.
    /// @dev Does NOT account for global trip state. Use `isTripped` to check effective state.
    /// @param guardedContract The address of the guarded contract.
    /// @param selector The 4-byte function selector to check.
    /// @return True if the function is specifically tripped.
    function isFunctionTripped(address guardedContract, bytes4 selector) external view returns (bool);

    /// @notice Check if a contract is globally tripped.
    /// @param guardedContract The address of the guarded contract.
    /// @return True if the contract is globally tripped.
    function isGloballyTripped(address guardedContract) external view returns (bool);

    /// @notice Check if an address is an operator for a guarded contract.
    /// @param guardedContract The address of the guarded contract.
    /// @param account The address to check.
    /// @return True if the address is an operator.
    function isOperator(address guardedContract, address account) external view returns (bool);

    /// @notice Get the guardian address for a guarded contract.
    /// @param guardedContract The address of the guarded contract.
    /// @return The guardian address, or address(0) if not registered.
    function guardian(address guardedContract) external view returns (address);

    /// @notice Get the pending guardian address for a guarded contract.
    /// @param guardedContract The address of the guarded contract.
    /// @return The pending guardian address, or address(0) if no transfer is pending.
    function pendingGuardian(address guardedContract) external view returns (address);
}
