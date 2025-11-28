// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ITokenLockupPlans} from "./interfaces/ITokenLockupPlans.sol";
import {IERC20} from "./interfaces/IERC20.sol";

interface IStratOption {
    function notionalUnderlyingAmount(uint256 tokenId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
}

/**
 * @title ClaimStratStream
 * @notice Allows oStrat holders (tokenId <= 466) to claim a streaming lockup plan for their STRAT tokens
 * @dev Each oStrat NFT can only be claimed once, and the caller must own the NFT
 */
contract ClaimStratStream {
    /// @notice Maximum tokenId that can claim (inclusive)
    uint256 public constant MAX_CLAIMABLE_TOKEN_ID = 466;

    /// @notice Start and cliff timestamp for all lockup plans
    uint256 public constant VESTING_START = 1764417600; // Sat 29 Nov 2025 12:00:00 UTC

    /// @notice Duration in seconds over which tokens are distributed (2 months = 61 days)
    uint256 public constant VESTING_DURATION_SECONDS = 5270400;

    /// @notice Period for lockup (1 second for streaming)
    uint256 public constant VESTING_RATE_PERIOD = 1;

    /// @notice oStrat NFT contract
    IStratOption public immutable stratOption;

    /// @notice STRAT token address
    address public immutable stratToken;

    /// @notice TokenLockupPlans contract address
    ITokenLockupPlans public immutable tokenLockupPlans;

    /// @notice Source address from which STRAT is pulled
    address public immutable stratSource;

    /// @notice Emergency pauser address
    address public immutable emergencyPauser;

    /// @notice Whether claiming is paused
    bool public paused;

    /// @notice Mapping of oStrat tokenId => whether it has been claimed
    mapping(uint256 => bool) public hasClaimed;

    error AlreadyClaimed(uint256 tokenId);
    error NotPresaylor(uint256 tokenId);
    error ClaimingPaused();
    error OnlyEmergencyPauser();

    event Claimed(
        address indexed claimant, uint256 indexed oStratTokenId, uint256 indexed lockupPlanId, uint256 amount
    );
    event Paused(address indexed pauser);
    event Unpaused(address indexed pauser);

    /**
     * @param _stratOption oStrat NFT contract address
     * @param _stratToken STRAT token address
     * @param _tokenLockupPlans TokenLockupPlans contract address
     * @param _stratSource Source address from which STRAT is pulled
     * @param _emergencyPauser Address that can pause/unpause claiming
     */
    constructor(
        address _stratOption,
        address _stratToken,
        address _tokenLockupPlans,
        address _stratSource,
        address _emergencyPauser
    ) {
        stratOption = IStratOption(_stratOption);
        stratToken = _stratToken;
        tokenLockupPlans = ITokenLockupPlans(_tokenLockupPlans);
        stratSource = _stratSource;
        emergencyPauser = _emergencyPauser;

        // Approve unlimited allowance for TokenLockupPlans to pull STRAT
        IERC20(_stratToken).approve(_tokenLockupPlans, type(uint256).max);
    }

    /**
     * @notice Claim a streaming lockup plan for an oStrat NFT
     * @param tokenId The oStrat tokenId to claim for (must be <= 466)
     * @return lockupPlanId The ID of the created lockup plan
     * @dev The caller must have approved this contract to transfer the NFT
     */
    function claim(uint256 tokenId) external returns (uint256 lockupPlanId) {
        if (paused) revert ClaimingPaused();
        if (tokenId > MAX_CLAIMABLE_TOKEN_ID) revert NotPresaylor(tokenId);
        if (hasClaimed[tokenId]) revert AlreadyClaimed(tokenId);
        if (stratOption.ownerOf(tokenId) != msg.sender) revert NotPresaylor(tokenId);

        // Mark as claimed
        hasClaimed[tokenId] = true;

        // Get the amount from the oStrat NFT before burning
        uint256 amount = stratOption.notionalUnderlyingAmount(tokenId);
        if (amount == 0) revert NotPresaylor(tokenId);

        // Transfer NFT from user to this contract, then burn it
        // This requires the user to have approved this contract
        stratOption.transferFrom(msg.sender, address(this), tokenId);
        stratOption.burn(tokenId);

        // Pull STRAT from source
        IERC20(stratToken).transferFrom(stratSource, address(this), amount);

        // Calculate rate: amount / LOCKUP_DURATION_SECONDS (distributes over 2 months)
        // NOTE: hedgey locker contract handles emitting any remainder tokens from the total amount
        uint256 rate = amount / VESTING_DURATION_SECONDS;

        // Create the lockup plan
        lockupPlanId = tokenLockupPlans.createPlan({
            recipient: msg.sender,
            token: stratToken,
            amount: amount,
            start: VESTING_START,
            cliff: VESTING_START,
            rate: rate,
            period: VESTING_RATE_PERIOD
        });

        emit Claimed(msg.sender, tokenId, lockupPlanId, amount);
    }

    /**
     * @notice Pause claiming (emergency only)
     * @dev Can only be called by the emergency pauser
     */
    function pause() external {
        if (msg.sender != emergencyPauser) revert OnlyEmergencyPauser();
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause claiming (emergency only)
     * @dev Can only be called by the emergency pauser
     */
    function unpause() external {
        if (msg.sender != emergencyPauser) revert OnlyEmergencyPauser();
        paused = false;
        emit Unpaused(msg.sender);
    }
}
