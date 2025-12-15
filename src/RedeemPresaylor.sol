// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";

interface IStratOption {
    function notionalUnderlyingAmount(uint256 tokenId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
}

/**
 * @title RedeemPresaylor
 * @notice Allows oStrat holders (tokenId <= 466) to redeem their option for WETH
 * @dev Each oStrat NFT can only be claimed once, and the caller must own the NFT
 */
contract RedeemPresaylor {
    /// @notice Maximum tokenId that can claim (inclusive)
    uint256 public constant MAX_CLAIMABLE_TOKEN_ID = 466;

    /// @notice oStrat NFT contract
    IStratOption public immutable stratOption;

    /// @notice Mapping of oStrat tokenId => whether it has been burned and redeemed
    mapping(uint256 => bool) public hasBurnedAndRedeemed;

    /// @notice WETH token address
    address public immutable weth;

    /// @notice Source address from which WETH is pulled
    address public immutable wethSource;

    /// @notice Emergency pauser address
    address public immutable emergencyPauser;

    /// @notice Whether claiming is paused
    bool public paused;

    error NotPresaylor(uint256 tokenId);
    error PresaylorRedeemedOrBurned(uint256 tokenId);
    error BurnAndRedeemPaused();
    error OnlyEmergencyPauser();

    event BurntAndRedeemed(
        address indexed caller, address indexed claimant, uint256 indexed oStratTokenId, uint256 wethAmount
    );
    event Paused(address indexed pauser);
    event Unpaused(address indexed pauser);

    /**
     * @param _stratOption oStrat NFT contract address
     * @param _wethSource Source address from which WETH is pulled
     * @param _emergencyPauser Address that can pause/unpause claiming
     */
    constructor(
        address _stratOption,
        address _weth,
        address _wethSource,
        address _emergencyPauser
    ) {
        stratOption = IStratOption(_stratOption);
        weth = _weth;
        wethSource = _wethSource;
        emergencyPauser = _emergencyPauser;
    }

    /**
     * @notice Redeem an oStrat NFT for WETH by burning the option
     * @param tokenId The oStrat tokenId to redeem for (must be <= 466)
     * @return wethAmount The amount of WETH sent to the caller
     * @dev The caller must have approved this contract to transfer the NFT
     */
    function burnAndRedeemForETH(uint256 tokenId) external returns (uint256 wethAmount) {
        if (paused) revert BurnAndRedeemPaused();
        if (tokenId > MAX_CLAIMABLE_TOKEN_ID) revert NotPresaylor(tokenId);
        if (stratOption.ownerOf(tokenId) != msg.sender) revert NotPresaylor(tokenId);

        hasBurnedAndRedeemed[tokenId] = true;

        // Get the amount from the oStrat NFT before burning
        uint256 notionalUnderlyingAmount = stratOption.notionalUnderlyingAmount(tokenId);
        address presaylor = stratOption.ownerOf(tokenId);
        if (notionalUnderlyingAmount == 0) revert PresaylorRedeemedOrBurned(tokenId);

        // Transfer NFT from user to this contract, then burn it
        // This requires the user to have approved this contract
        stratOption.transferFrom(msg.sender, address(this), tokenId);
        stratOption.burn(tokenId);

        // Calculate WETH amount: notionalUnderlyingAmount / 10_000 * 0.8e18 / 1e18
        // Which is: notionalUnderlyingAmount * 0.8e18 / 1e22
        wethAmount = notionalUnderlyingAmount * 0.8e18 / 1e22;

        // Pull WETH from source
        IERC20(weth).transferFrom(wethSource, presaylor, wethAmount);

        // Send WETH to caller
        // IERC20(weth).transfer(presaylor, wethAmount);

        emit BurntAndRedeemed(msg.sender, presaylor, tokenId, wethAmount);
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

