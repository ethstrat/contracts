// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title ITokenLockupPlans - Interface for Hedgey Finance TokenLockupPlans
/// @dev This interface provides the functions for interacting with Hedgey's TokenLockupPlans contract
///      used by eth strategy
interface ITokenLockupPlans {
    /// @notice Creates a new lockup plan
    /// @param recipient The address of the recipient and beneficiary of the plan
    /// @param token The address of the ERC20 token
    /// @param amount The amount of tokens to be locked in the plan
    /// @param start The start date of the lockup plan, unix time
    /// @param cliff A cliff date which is a discrete date where tokens are not unlocked until this date
    /// @param rate The amount of tokens that vest in a single period
    /// @param period The amount of time in between each unlock time stamp, in seconds
    /// @return newPlanId The ID of the newly created plan (also the NFT token ID)
    function createPlan(
        address recipient,
        address token,
        uint256 amount,
        uint256 start,
        uint256 cliff,
        uint256 rate,
        uint256 period
    ) external returns (uint256 newPlanId);
}

