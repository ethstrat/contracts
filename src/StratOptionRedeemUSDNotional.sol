// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IPriceService} from "./interfaces/IPriceService.sol";
import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";
import {IERC20, IERC20MintableBurnablePermit} from "./interfaces/IERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {Permit} from "./lib/Permit.sol";

/// @title StratOptionRedeemUSDNotional
/// @notice This contract allows a user to redeem their STRAT option for the underlying value of the option
contract StratOptionRedeemUSDNotional is Ownable2Step {
    using Permit for IERC20MintableBurnablePermit;

    IERC20MintableBurnablePermit public immutable cdtToken;
    ITreasury public immutable treasury;
    IStratOptionMinter public immutable stratOption;
    IPriceService public priceService;

    error NotOwnerOrApproved(address account, uint256 tokenId);
    error TimelockActive(address account, uint256 tokenId);
    error OptionUnexpired(address account, uint256 tokenId);
    error ZeroAddress();

    event OptionRedeemed(address indexed optionOwner, uint256 tokenId, uint256 notionalUSDAmount, uint256 ethAmount);
    event PriceServiceUpdated(address indexed oldPriceService, address indexed newPriceService);

    /**
     * @param _cdtToken The CDT token
     * @param _treasury STRAT treasury
     * @param _priceService The price service
     * @param _stratOption The STRAT option
     * @param owner The owner
     */
    constructor(address _cdtToken, address _treasury, address _priceService, address _stratOption, address owner)
        Ownable(owner)
    {
        if (_cdtToken == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_priceService == address(0)) revert ZeroAddress();
        if (_stratOption == address(0)) revert ZeroAddress();

        cdtToken = IERC20MintableBurnablePermit(_cdtToken);
        treasury = ITreasury(_treasury);
        stratOption = IStratOptionMinter(_stratOption);
        priceService = IPriceService(_priceService);
    }

    function setPriceService(address _newPriceService) external onlyOwner {
        if (_newPriceService == address(0)) revert ZeroAddress();

        address oldPriceService = address(priceService);
        priceService = IPriceService(_newPriceService);

        emit PriceServiceUpdated(oldPriceService, _newPriceService);
    }

    /// @notice Redeem STRAT option and CDT tokens for the USD notional value post option expiry, paid
    //          back in ETH
    /// @dev    The amount of ETH to withdraw from the treasury is calculated based on the following:
    ///           - If the treasury holds sufficient ETH (value in USD is higher than CDT total supply), the full USD
    /// notional
    ///             is converted into ETH at the current oracle price
    ///           - Otherwise, a proportional share of the treasury's ETH is provided
    ///
    ///         Uses the ERC-2612 permit mechanism to approve the CDT burn
    ///
    /// @param tokenId              The ID of the option to redeem
    /// @param cdtPermitApproval    The permit approval for the CDT tokens
    function redeemCdtForUsdNotionalWithPermit(uint256 tokenId, Permit.IPermitApproval memory cdtPermitApproval)
        public
    {
        if (stratOption.timelock(tokenId) > block.timestamp) revert TimelockActive(msg.sender, tokenId);
        if (stratOption.expiry(tokenId) > block.timestamp) revert OptionUnexpired(msg.sender, tokenId);

        uint256 notionalUSDAmount = stratOption.notionalUSDAmount(tokenId);
        uint256 totalDebt = cdtToken.totalSupply();
        (uint256 ethUsdPrice, uint256 ethUsdPriceScale) = priceService.getEthUsdPrice();
        uint256 treasuryInETH = treasury.total();
        uint256 treasuryInUSD = treasuryInETH * ethUsdPrice / ethUsdPriceScale;
        address optionOwner = stratOption.ownerOf(tokenId);

        // Burn CDT and STRAT option
        cdtToken.validatePermit(msg.sender, address(this), notionalUSDAmount, cdtPermitApproval);
        cdtToken.burnFrom(msg.sender, notionalUSDAmount);
        stratOption.burn(tokenId);

        uint256 ethAmount = 0;
        if (treasuryInUSD > cdtToken.totalSupply()) {
            ethAmount = notionalUSDAmount * ethUsdPriceScale / ethUsdPrice;
        } else {
            ethAmount = notionalUSDAmount * treasuryInETH / totalDebt;
        }

        treasury.withdraw(ethAmount, optionOwner);
        emit OptionRedeemed(optionOwner, tokenId, notionalUSDAmount, ethAmount);
    }

    /// @notice Redeem STRAT option and CDT tokens for the USD notional value post option expiry, paid
    //          back in ETH
    /// @dev    This is the same as {redeemCdtForUsdNotionalWithPermit}, but without the permit approval
    ///
    /// @param tokenId  The ID of the option to redeem
    function redeemCdtForUsdNotional(uint256 tokenId) external {
        redeemCdtForUsdNotionalWithPermit(tokenId, Permit.getEmptyApproval());
    }
}
