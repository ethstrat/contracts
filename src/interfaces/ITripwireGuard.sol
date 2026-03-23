// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITripwireController} from "./ITripwireController.sol";

/// @title ITripwireGuard
/// @author SigIntZero
/// @custom:version v1.0
/// @custom:date 2026-03-12
/// @notice Interface for contracts that integrate Tripwire circuit breaker protection.
/// @dev Contracts implementing this interface declare themselves as guardable by a
/// Tripwire controller. The controller address is exposed so that external systems
/// can verify the protection configuration.
interface ITripwireGuard {
    /// @notice The function or contract has been tripped by the Tripwire controller.
    /// @param selector The function selector that was tripped, or bytes4(0) for global trips.
    error Tripped(bytes4 selector);

    /// @notice The controller address provided at construction was invalid (zero or no code).
    error InvalidController();

    /// @notice Returns the Tripwire controller that this contract defers to.
    /// @return The ITripwireController instance.
    function controller() external view returns (ITripwireController);
}
