// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";
import {IERC20, IERC20MintableBurnablePermit} from "./interfaces/IERC20.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {Permit} from "./lib/Permit.sol";

/// @title StratOptionRedeemUSDNotional
/// @notice This contract allows a user to redeem their STRAT option for the underlying value of the option
contract StratOptionRedeemUSDNotional {
    using Permit for IERC20MintableBurnablePermit;

    IERC20MintableBurnablePermit public immutable cdtToken;
    IERC20 public immutable stratToken;
    ITreasury public immutable treasury;
    IOracle public immutable ethUsdOracle;
    IStratOptionMinter public immutable stratOption;
    uint256 public immutable oracleScale;

    error NotOwnerOrApproved(address account, uint256 tokenId);
    error TimelockActive(address account, uint256 tokenId);
    error OptionUnexpired(address account, uint256 tokenId);

    event OptionRedeemed(address indexed optionOwner, uint256 tokenId, uint256 notionalUSDAmount, uint256 ethAmount);

    /**
     * @param _cdtToken The CDT token
     * @param _stratOption The STRAT option
     * @param _treasury STRAT treasury
     * @param _ethUsdOracle The ETH/USD oracle
     * @param _stratOption The STRAT option
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _treasury,
        address _ethUsdOracle,
        address _stratOption
    ) {
        cdtToken = IERC20MintableBurnablePermit(_cdtToken);
        stratToken = IERC20(_stratToken);
        treasury = ITreasury(_treasury);
        ethUsdOracle = IOracle(_ethUsdOracle);
        stratOption = IStratOptionMinter(_stratOption);
        oracleScale = 10 ** ethUsdOracle.quoteTokenDecimals();
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
        uint256 ethPriceUSD = ethUsdOracle.price();
        uint256 treasuryInETH = treasury.total();
        uint256 treasuryInUSD = treasuryInETH * ethPriceUSD / oracleScale;
        address optionOwner = stratOption.ownerOf(tokenId);

        // Burn CDT and STRAT option
        cdtToken.validatePermit(msg.sender, address(this), notionalUSDAmount, cdtPermitApproval);
        cdtToken.burnFrom(msg.sender, notionalUSDAmount);
        stratOption.burn(tokenId);

        uint256 ethAmount = 0;
        if (treasuryInUSD > cdtToken.totalSupply()) {
            ethAmount = notionalUSDAmount * oracleScale / ethPriceUSD;
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
        redeemCdtForUsdNotionalWithPermit(
            tokenId, Permit.IPermitApproval({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)})
        );
    }
}
