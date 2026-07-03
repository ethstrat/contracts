// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITripwireController} from "../interfaces/ITripwireController.sol";
import {ITripwireGuard} from "../interfaces/ITripwireGuard.sol";

/// @title TripwireGuard
/// @author SigIntZero
/// @custom:version v1.0
/// @custom:date 2026-03-12
/// @notice Abstract base contract for protocols integrating Tripwire circuit breaker protection.
/// @dev Inherit this contract and apply `whenNotTripped` or `whenNotGloballyTripped` modifiers
/// to functions that should be pausable by the Tripwire controller.
///
/// Example usage:
/// ```solidity
/// contract MyVault is TripwireGuard {
///     constructor(ITripwireController controller_, address guardian_)
///         TripwireGuard(controller_, guardian_) {}
///
///     function withdraw(uint256 amount) external whenNotTripped {
///         // Individually pausable OR globally pausable
///     }
///
///     function deposit(uint256 amount) external whenNotGloballyTripped {
///         // Only affected by global pauses
///     }
/// }
/// ```
abstract contract TripwireGuard is ITripwireGuard {
    /// @dev The immutable Tripwire controller. Set once at construction.
    ITripwireController private immutable _CONTROLLER;

    /// @param controller_ The ITripwireController to defer to. Must be a deployed contract.
    /// @param guardian_ The guardian address for this contract's circuit breaker management.
    constructor(ITripwireController controller_, address guardian_) {
        if (address(controller_) == address(0) || address(controller_).code.length == 0) {
            revert InvalidController();
        }
        _CONTROLLER = controller_;
        controller_.register(address(this), guardian_);
    }

    /// @notice Reverts if this function is tripped OR the contract is globally tripped.
    /// @dev Uses `msg.sig` to resolve the calling function's selector automatically.
    /// Gas: single external view call (~200 gas warm, ~2300 gas cold).
    modifier whenNotTripped() {
        _requireNotTripped(msg.sig);
        _;
    }

    /// @notice Reverts if the contract is globally tripped.
    /// @dev Does NOT check per-function trip state. Use when function-level
    /// granularity is not needed.
    /// Gas: single external view call (~200 gas warm, ~2300 gas cold).
    modifier whenNotGloballyTripped() {
        _requireNotGloballyTripped();
        _;
    }

    /// @inheritdoc ITripwireGuard
    function controller() external view returns (ITripwireController) {
        return _CONTROLLER;
    }

    /// @dev Reverts with `Tripped(selector)` if function-level or global trip is active.
    function _requireNotTripped(bytes4 selector) internal view {
        if (_CONTROLLER.isTripped(address(this), selector)) {
            revert Tripped(selector);
        }
    }

    /// @dev Reverts with `Tripped(0x00000000)` if global trip is active.
    function _requireNotGloballyTripped() internal view {
        if (_CONTROLLER.isGloballyTripped(address(this))) {
            revert Tripped(bytes4(0));
        }
    }
}
