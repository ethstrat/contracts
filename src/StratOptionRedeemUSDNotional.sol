// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {EthUsdPriceFeedConsumer} from "./lib/EthUsdPriceFeedConsumer.sol";

import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";
import {IERC20, IERC20MintableBurnablePermit} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {Permit} from "./lib/Permit.sol";

/**
 * @title StratOptionRedeemUSDNotional
 * @notice This contract allows a user to redeem their STRAT option for the underlying value of the option
 */
contract StratOptionRedeemUSDNotional is EthUsdPriceFeedConsumer {
    using Permit for IERC20MintableBurnablePermit;

    IERC20MintableBurnablePermit public immutable cdtToken;
    ITreasury public immutable treasury;
    IStratOptionMinter public immutable stratOption;

    error TimelockActive(address account, uint256 tokenId);
    error OptionUnexpired(address account, uint256 tokenId);
    error Unsupported(address account, uint256 tokenId);
    error InvalidTokenId(address account, uint256 tokenId);

    event OptionRedeemed(address indexed optionOwner, uint256 tokenId, uint256 notionalUSDAmount, uint256 ethAmount);

    /**
     * @param _cdtToken The CDT token
     * @param _stratOption The STRAT option
     * @param _treasury STRAT treasury
     * @param _ethUsdOracle The ETH/USD oracle
     * @param _stratOption The STRAT option
     */
    constructor(address _cdtToken, address _treasury, address _ethUsdOracle, address _stratOption)
        EthUsdPriceFeedConsumer(_ethUsdOracle)
    {
        cdtToken = IERC20MintableBurnablePermit(_cdtToken);
        treasury = ITreasury(_treasury);
        stratOption = IStratOptionMinter(_stratOption);
    }

    /**
     * @notice  Redeem STRAT option and CDT tokens for the USD notional value post option expiry, paid
     *          back in ETH
     * @dev     The amount of ETH to withdraw from the treasury is calculated based on the following:
     *          - If the treasury holds sufficient ETH (value in USD is higher than CDT total supply), the full USD
     *            notional is converted into ETH at the current oracle price
     *          - Otherwise, a proportional share of the treasury's ETH is provided
     *
     *          Uses the ERC-2612 permit mechanism to approve the CDT burn
     *
     * @param   tokenId             The ID of the option to redeem
     * @param   cdtPermitApproval   The permit approval for the CDT tokens
     */
    function redeemCdtForUsdNotionalWithPermit(uint256 tokenId, Permit.IPermitApproval memory cdtPermitApproval)
        public
    {
        uint256 timelock = stratOption.timelock(tokenId);
        if (timelock == 0) revert InvalidTokenId(msg.sender, tokenId);
        if (timelock > block.timestamp) revert TimelockActive(msg.sender, tokenId);
        if (stratOption.expiry(tokenId) > block.timestamp) revert OptionUnexpired(msg.sender, tokenId);

        uint256 notionalUSDAmount = stratOption.notionalUSDAmount(tokenId);
        // Presale options have a notional USD amount of 0, so cannot be redeemed
        if (notionalUSDAmount == 0) revert Unsupported(msg.sender, tokenId);

        uint256 totalDebt = cdtToken.totalSupply(); // Scale: 18 decimals
        uint256 ethPriceUSD = _getEthUsdPrice(); // Scale: 18 decimals
        uint256 treasuryInETH = treasury.total(); // Scale: 18 decimals
        uint256 treasuryInUSD = treasuryInETH * ethPriceUSD / _ETH_USD_ORACLE_SCALE; // Scale: 18 decimals
        address optionOwner = stratOption.ownerOf(tokenId);

        // Burn CDT and STRAT option
        cdtToken.validatePermit(msg.sender, address(this), notionalUSDAmount, cdtPermitApproval);
        cdtToken.burnFrom(msg.sender, notionalUSDAmount);
        stratOption.burn(tokenId);

        // If the value of the treasury (ETH) in USD is more than the USD debt
        uint256 ethAmount = 0;
        if (treasuryInUSD > totalDebt) {
            // The notional USD amount of the deposit is converted to ETH at the time of redemption
            // Depending on the ETH price at the time of redemption, the option owner can receive more or less than the
            // ETH deposit amount
            //
            // e.g. if 2e18 ETH @ 2000e18 is deposited, the notional USD amount is 4000e18.
            // At the time of redemption:
            // - if the ETH price is 3000e18, the ETH returned will be 4000e18 * 1e18 / 3000e18 = 1.3333e18 ETH
            // - if the ETH price is 1500e18, the ETH returned will be 4000e18 * 1e18 / 1500e18 = 2.6666e18 ETH
            ethAmount = notionalUSDAmount * _ETH_USD_ORACLE_SCALE / ethPriceUSD;
        }
        // Otherwise, the value of the treasury (ETH) in USD is less than the USD value of what was bonded
        else {
            // The option owner receives the proportional amount of ETH in the treasury
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
