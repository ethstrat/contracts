// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {EthUsdPriceFeedConsumer} from "./lib/EthUsdPriceFeedConsumer.sol";
import {TokenURIRenderer} from "./interfaces/TokenURIRenderer.sol";
import {esETH} from "./esETH.sol";

import {IERC20, IERC20MintableBurnable, IERC20MintableBurnablePermit} from "./interfaces/IERC20.sol";
import {Permit} from "./lib/Permit.sol";
import {ITripwireController} from "./interfaces/ITripwireController.sol";
import {TripwireGuard} from "./lib/TripwireGuard.sol";

/**
 * @title The ETH Strategy Convertible Note
 * @dev NFT-based convertible notes on STRAT. Bonders get CDT and an NFT representing the option.
 */
contract EthStrategyConvertibleNote is ERC721, Ownable2Step, EthUsdPriceFeedConsumer, TripwireGuard {
    using Permit for IERC20MintableBurnablePermit;

    uint256 public _tokenIdCounter;

    IERC20MintableBurnablePermit public immutable cdtToken;
    IERC20MintableBurnable public immutable stratToken;
    esETH public immutable esETHToken;
    address immutable unencumberedHoldings; // Address that holds unencumbered ETH
    address immutable encumberedHoldings; // Address that holds encumbered ETH (backs open unexercised options)

    uint256 public pcf; // Premium Control Factor (scale: SCALE)
    uint256 public gcf; // GAV Control Factor (scale: SCALE)
    address public tokenURIRenderer;

    /// @notice The amount of CDT required to exercise/settle the note (remaining if partially exercised)
    /// @dev    Scale: SCALE
    mapping(uint256 tokenId => uint256) public amountOwedCdt;

    /// @notice The amount of STRAT the note holder is entitled to receive on conversion (remaining if partially
    /// exercised)
    /// @dev    Scale: SCALE
    mapping(uint256 tokenId => uint256) public conversionEntitlementStrat;

    /// @notice The amount of ETH the note holder is entitled to receive on conversion to ETH (remaining if partially
    /// converted)
    /// @dev    Scale: 1e18 (wei)
    mapping(uint256 tokenId => uint256) public conversionEntitlementEth;

    /// @notice The USD-notional settlement entitlement (paid out in esETH) (remaining if partially exercised)
    /// @dev    Scale: SCALE
    mapping(uint256 tokenId => uint256) public settlementEntitlementUsd;

    /// @notice The timestamp before which the holder can convert to STRAT or ETH (after expiry, holder can reclaim
    ///         the CDT at $1 - that is, have their initial notional dollar value repaid)
    mapping(uint256 tokenId => uint256) public expiry;

    /// @notice The timestamp after which the holder can exwrcise conversion rights
    mapping(uint256 tokenId => uint256) public timelock;

    /// @notice Whether the encumbered ETH backing an expired note has been administratively
    ///         moved to unencumbered holdings (via releaseEncumbrance) before the holder redeems.
    mapping(uint256 tokenId => bool) public encumbranceReleased;

    uint256 public constant SCALE = 1e18;

    event OwnerChangedPCF(uint256 oldVal, uint256 newVal);
    event OwnerChangedGCF(uint256 oldVal, uint256 newVal);
    event RendererUpdated(address indexed renderer);
    event EncumbranceReleased(uint256 indexed tokenId, uint256 ethAmount);

    event LongBond(
        address indexed bonder,
        uint256 indexed tokenId,
        uint256 strike,
        uint256 notionalUnderlyingAmount,
        uint256 notionalUSDAmount,
        uint256 ethAmount,
        uint256 expiry,
        uint256 timelock
    );

    event Conversion(
        address indexed optionOwner,
        uint256 indexed tokenId,
        uint256 cdtBurned,
        uint256 stratOut,
        uint256 ethOut,
        uint256 remainingStrat,
        uint256 remainingEth,
        uint256 remainingUsd
    );
    event Redemption(
        address indexed optionOwner, uint256 indexed tokenId, uint256 notionalUSDAmount, uint256 ethAmount
    );

    error NoEthSent();
    error ZeroAddress();
    error EthTransferFailed();
    error TransactionStale(uint256 deadline);
    error InsufficientOutput(uint256 minNotionalUnderlyingAmount, uint256 notionalUnderlyingAmount);
    error NotOwnerOrApproved(address account, uint256 tokenId);
    error TimelockActive(address account, uint256 tokenId);
    error OptionExpired(address account, uint256 tokenId);
    error OptionUnexpired(address account, uint256 tokenId);
    error InvalidTimelockOrExpiry(uint256 timelock, uint256 expiry);
    error InvalidExerciseAmount(uint256 amount, uint256 remainingStrike);
    error EncumbranceAlreadyReleased(uint256 tokenId);

    /**
     * @param _cdtToken The CDT token
     * @param _stratToken The STRAT token
     * @param _esETHToken The esETH token
     * @param _unencumberedHoldings Address that holds unencumbered ETH
     * @param _encumberedHoldings Address that holds encumbered ETH (backs open unexercised options)
     * @param _ethUsdOracle The ETH/USD oracle
     * @param owner The owner
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _esETHToken,
        address _unencumberedHoldings,
        address _encumberedHoldings,
        address _ethUsdOracle,
        address owner,
        ITripwireController controller_,
        address guardian_
    ) ERC721("ETH Strategy Convertible Note", "esCN") Ownable(owner) EthUsdPriceFeedConsumer(_ethUsdOracle) TripwireGuard(controller_, guardian_) {
        cdtToken = IERC20MintableBurnablePermit(_cdtToken);
        stratToken = IERC20MintableBurnable(_stratToken);
        esETHToken = esETH(_esETHToken);
        unencumberedHoldings = _unencumberedHoldings;
        encumberedHoldings = _encumberedHoldings;

        pcf = 1 * SCALE;
        gcf = 1 * SCALE;
        _tokenIdCounter = 1;
    }

    /**
     * @notice Updates the premium control factor (PCF)
     * @dev Only the contract owner can call this function.
     * @param newVal The new PCF value to be set.
     */
    function setPCF(uint256 newVal) external onlyOwner {
        emit OwnerChangedPCF(pcf, newVal);
        pcf = newVal;
    }

    /**
     * @notice Updates the GAV control factor (GCF)
     * @dev Only the contract owner can call this function.
     * @param newVal The new GCF value to be set.
     */
    function setGCF(uint256 newVal) external onlyOwner {
        emit OwnerChangedGCF(gcf, newVal);
        gcf = newVal;
    }

    /**
     * @dev Allows only the owner can update the token URI renderer.
     */
    function managerRenderer(address renderer) external onlyOwner {
        tokenURIRenderer = renderer;
        emit RendererUpdated(renderer);
    }

    /**
     * @notice Moves the encumbered ETH backing an expired note into unencumbered holdings.
     * @dev    Only callable by the owner after the note has expired. This allows the protocol to
     *         administratively free collateral before (or independently of) the holder calling
     *         redeemCdtForUsdNotional. Once released, redemption will skip the redundant transfer.
     *
     *         Reverts if the note does not exist / has already been settled, if it has not yet
     *         expired, or if the encumbrance was already released for this tokenId.
     *
     * @param tokenId The ID of the expired note whose encumbered collateral to release.
     */
    function releaseEncumbrance(uint256 tokenId) external onlyOwner {
        if (expiry[tokenId] == 0 || expiry[tokenId] > block.timestamp) {
            revert OptionUnexpired(msg.sender, tokenId);
        }
        if (encumbranceReleased[tokenId]) revert EncumbranceAlreadyReleased(tokenId);

        encumbranceReleased[tokenId] = true;
        uint256 ethToRelease = conversionEntitlementEth[tokenId];
        if (ethToRelease > 0) {
            esETHToken.transferFrom(encumberedHoldings, unencumberedHoldings, ethToRelease);
        }
        emit EncumbranceReleased(tokenId, ethToRelease);
    }

    function bond(address bonder, uint256 minConversionAmountStrat, uint256 minConversionAmountEth, uint256 deadline)
        external
        payable
        whenNotTripped
    {
        if (msg.value == 0) revert NoEthSent();
        if (bonder == address(0)) revert ZeroAddress();
        if (deadline < block.timestamp) revert TransactionStale(deadline);

        // settlement notional in USD
        uint256 ethPriceUSD = _getEthUsdPrice();
        uint256 settlementAmountUsd_ = msg.value * ethPriceUSD / _ETH_USD_ORACLE_SCALE; // Scale: 18 decimals
        (uint256 conversionAmountStrat_, uint256 conversionAmountEth_) = conversionEntitlements(settlementAmountUsd_);

        // Check that the notional underlying amount is greater than the minimum
        if (conversionAmountStrat_ < minConversionAmountStrat) {
            revert InsufficientOutput(minConversionAmountStrat, conversionAmountStrat_);
        }
        if (conversionAmountEth_ < minConversionAmountEth) {
            revert InsufficientOutput(minConversionAmountEth, conversionAmountEth_);
        }

        uint256 tokenId = _tokenIdCounter++;
        uint256 expiry_ = block.timestamp + (4.2 * 365 days);
        uint256 timelock_ = block.timestamp + 6.9 days;

        // Validate timelock and expiry
        if (block.timestamp > timelock_ || timelock_ > expiry_) {
            revert InvalidTimelockOrExpiry(timelock_, expiry_);
        }

        // Mint NFT
        _mint(bonder, tokenId);
        amountOwedCdt[tokenId] = settlementAmountUsd_;
        conversionEntitlementStrat[tokenId] = conversionAmountStrat_;
        conversionEntitlementEth[tokenId] = conversionAmountEth_;
        settlementEntitlementUsd[tokenId] = settlementAmountUsd_;
        expiry[tokenId] = expiry_;
        timelock[tokenId] = timelock_;

        // Mint CDT to the bonder
        cdtToken.mint(bonder, settlementAmountUsd_);

        // Send the eth to the well known address where we hold all our encumbered ETH (as these back
        // the semantic covered calls embedded in the conversion rights)
        if (conversionAmountEth_ > 0) {
            esETHToken.wrapAndMint{value: conversionAmountEth_}(encumberedHoldings);
        }

        // send the remainder of the ETH to the unencumbered holdings
        esETHToken.wrapAndMint{value: msg.value - conversionAmountEth_}(unencumberedHoldings);

        emit LongBond(
            bonder,
            tokenId,
            settlementAmountUsd_, // strike / CDT owed
            conversionAmountStrat_, // notional underlying (STRAT)
            settlementAmountUsd_, // notional USD
            msg.value, // ETH bonded
            expiry_,
            timelock_
        );
    }

    /**
     * @notice Converts a note (partially or fully) into either STRAT or ETH before expiry,
     *         using an ERC-2612 permit for CDT approval.
     *
     * @param tokenId The identifier of the note token to convert.
     * @param cdtToBurn Amount of CDT to burn for this conversion (partial conversion supported).
     * @param toEth If true, convert to ETH; otherwise convert to STRAT.
     * @param cdtPermitApproval The permit approval for the CDT tokens.
     */
    function convertPartialWithPermit(
        uint256 tokenId,
        uint256 cdtToBurn,
        bool toEth,
        Permit.IPermitApproval memory cdtPermitApproval
    ) public whenNotTripped {
        // Check that the timelock period has passed.
        if (timelock[tokenId] > block.timestamp) {
            revert TimelockActive(msg.sender, tokenId);
        }

        // Conversion is strictly before expiry; at t == expiry only redemption is valid (no overlap).
        if (expiry[tokenId] <= block.timestamp) {
            revert OptionExpired(msg.sender, tokenId);
        }

        // Retrieve the owner of the option token.
        address optionOwner = ownerOf(tokenId);

        // Check that the sender is either the owner
        // TODO: should we extend for NFT approvals? Unsure if the complexity/attack surface is worth it
        if (msg.sender != optionOwner) {
            revert NotOwnerOrApproved(msg.sender, tokenId);
        }

        // Retrieve remaining position state.
        uint256 amountOwedCdt_ = amountOwedCdt[tokenId];
        uint256 settlementEntitlementUsd_ = settlementEntitlementUsd[tokenId];
        uint256 conversionEntitlementStrat_ = conversionEntitlementStrat[tokenId];
        uint256 conversionEntitlementEth_ = conversionEntitlementEth[tokenId];

        if (cdtToBurn == 0 || cdtToBurn > amountOwedCdt_) {
            revert InvalidExerciseAmount(cdtToBurn, amountOwedCdt_);
        }

        // Pro-rata outputs for this conversion chunk
        uint256 stratOut = conversionEntitlementStrat_ * cdtToBurn / amountOwedCdt_;
        uint256 ethOut = conversionEntitlementEth_ * cdtToBurn / amountOwedCdt_;

        // Burn the corresponding amount from the sender
        cdtToken.validatePermit(msg.sender, address(this), cdtToBurn, cdtPermitApproval);
        cdtToken.burnFrom(msg.sender, cdtToBurn);

        // Move eth from encumbered holdings to unencumbered holdings, preparing for conversion
        esETHToken.transferFrom(encumberedHoldings, unencumberedHoldings, ethOut);

        // either send esETH to the option owner or mint STRAT
        if (toEth) {
            esETHToken.transferFrom(unencumberedHoldings, optionOwner, ethOut);
        } else {
            stratToken.mint(optionOwner, stratOut);
        }

        // Update remaining position balances in-place (partial conversion)
        uint256 remainingAmountOwedCdt_ = amountOwedCdt_ - cdtToBurn;
        uint256 remainingConversionEntitlementStrat_ = conversionEntitlementStrat_ - stratOut;
        uint256 remainingSettlementEntitlementUsd_ = settlementEntitlementUsd_ - cdtToBurn;
        uint256 remainingConversionEntitlementEth_ = conversionEntitlementEth_ - ethOut;

        amountOwedCdt[tokenId] = remainingAmountOwedCdt_;
        conversionEntitlementStrat[tokenId] = remainingConversionEntitlementStrat_;
        settlementEntitlementUsd[tokenId] = remainingSettlementEntitlementUsd_;
        conversionEntitlementEth[tokenId] = remainingConversionEntitlementEth_;

        // Fully settled => burn the NFT and clear timestamps
        if (remainingAmountOwedCdt_ == 0) {
            expiry[tokenId] = 0;
            timelock[tokenId] = 0;
            _burn(tokenId);
        }
        emit Conversion(
            optionOwner,
            tokenId,
            cdtToBurn,
            stratOut,
            ethOut,
            remainingConversionEntitlementStrat_,
            remainingConversionEntitlementEth_,
            remainingSettlementEntitlementUsd_
        );
    }

    /**
     * @notice Fully converts a note to STRAT, using an ERC-2612 permit.
     * @dev Kept for backwards-compatibility with earlier integrations/tests.
     */
    function convertWithPermit(uint256 tokenId, Permit.IPermitApproval memory cdtPermitApproval) external whenNotTripped {
        convertPartialWithPermit(tokenId, amountOwedCdt[tokenId], false, cdtPermitApproval);
    }

    /**
     * @notice Fully converts a note to STRAT (no permit).
     *
     * @param tokenId The identifier of the option token to exercise.
     */
    function convert(uint256 tokenId, bool toEth) external whenNotTripped {
        convertPartialWithPermit(tokenId, amountOwedCdt[tokenId], toEth, Permit.getEmptyApproval());
    }

    /**
     * @notice Partially converts a note to STRAT (no permit).
     */
    function convertPartial(uint256 tokenId, bool toEth, uint256 cdtToBurn) external whenNotTripped {
        convertPartialWithPermit(tokenId, cdtToBurn, toEth, Permit.getEmptyApproval());
    }

    /// @notice Redeem option and CDT tokens for the USD notional value post option expiry, paid
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
    /// @param minEthOut            Minimum acceptable esETH output amount for slippage protection
    /// @param cdtPermitApproval    The permit approval for the CDT tokens
    function redeemCdtForUsdNotionalWithPermit(
        uint256 tokenId,
        uint256 minEthOut,
        Permit.IPermitApproval memory cdtPermitApproval
    )
        public
        whenNotTripped
    {
        // Redundant with the expiry check below (bonding enforces expiry > timelock, so redeem only runs after
        // timelock has passed). Intentionally retained: same ordering as convert, explicit TimelockActive reverts,
        // and readable completeness at the cost of a small amount of gas.
        if (timelock[tokenId] > block.timestamp) revert TimelockActive(msg.sender, tokenId);
        if (expiry[tokenId] > block.timestamp) revert OptionUnexpired(msg.sender, tokenId);

        uint256 settlementEntitlementUsd_ = settlementEntitlementUsd[tokenId];
        uint256 totalDebt = cdtToken.totalSupply();
        uint256 ethPriceUSD = _getEthUsdPrice();
        address optionOwner = ownerOf(tokenId);

        // Check the caller is either the option owner
        // TODO: should we extend for NFT approvals? Unsure if the complexity/attack surface is worth it
        if (msg.sender != optionOwner) {
            revert NotOwnerOrApproved(msg.sender, tokenId);
        }

        // Burn CDT
        cdtToken.validatePermit(msg.sender, address(this), settlementEntitlementUsd_, cdtPermitApproval);

        // Move eth from encumbered holdings to unencumbered holdings, preparing for redemption.
        // Skip if the owner already released this encumbrance via releaseEncumbrance().
        if (!encumbranceReleased[tokenId]) {
            esETHToken.transferFrom(encumberedHoldings, unencumberedHoldings, conversionEntitlementEth[tokenId]);
        }

        uint256 ethAmount = 0;
        uint256 unencumberedEth = esETHToken.balanceOf(unencumberedHoldings);
        uint256 encumberedEth = esETHToken.balanceOf(encumberedHoldings);
        uint256 totalTreasuryEth = unencumberedEth + encumberedEth;
        uint256 treasuryInUSD = totalTreasuryEth * ethPriceUSD / _ETH_USD_ORACLE_SCALE;
        if (treasuryInUSD > cdtToken.totalSupply()) {
            // If solvent, pay the USD notional at the current ETH/USD rate
            ethAmount = settlementEntitlementUsd_ * _ETH_USD_ORACLE_SCALE / ethPriceUSD;
        } else {
            ethAmount = settlementEntitlementUsd_ * totalTreasuryEth / totalDebt;
        }
        if (ethAmount < minEthOut) {
            revert InsufficientOutput(minEthOut, ethAmount);
        }

        // Clear the option data
        amountOwedCdt[tokenId] = 0;
        conversionEntitlementStrat[tokenId] = 0;
        settlementEntitlementUsd[tokenId] = 0;
        conversionEntitlementEth[tokenId] = 0;
        expiry[tokenId] = 0;
        timelock[tokenId] = 0;
        delete encumbranceReleased[tokenId];

        // Burn the NFT
        _burn(tokenId);

        // Burn CDT
        cdtToken.burnFrom(msg.sender, settlementEntitlementUsd_);

        // Send ETH to the note holder
        esETHToken.transferFrom(unencumberedHoldings, optionOwner, ethAmount);
        emit Redemption(optionOwner, tokenId, settlementEntitlementUsd_, ethAmount);
    }

    /// @notice Redeem option and CDT tokens for the USD notional value post option expiry, paid
    //          back in ETH
    /// @dev    This is the same as {redeemCdtForUsdNotionalWithPermit}, but without the permit approval
    ///
    /// @param tokenId    The ID of the option to redeem
    /// @param minEthOut  Minimum acceptable esETH output amount for slippage protection
    function redeemCdtForUsdNotional(uint256 tokenId, uint256 minEthOut) external whenNotTripped {
        redeemCdtForUsdNotionalWithPermit(tokenId, minEthOut, Permit.getEmptyApproval());
    }

    /// @notice Returns the STRAT amount the holder is entitled to receive for a given USD notional.
    /// @dev Scale: 1e18 (STRAT decimals).
    function conversionEntitlements(uint256 settlementEntitlementUsd_)
        public
        view
        returns (uint256 stratAmount, uint256 ethAmount)
    {
        uint256 ethPriceUSD = _getEthUsdPrice();
        uint256 totalEth = esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);
        uint256 gavUSD = totalEth * ethPriceUSD / _ETH_USD_ORACLE_SCALE;

        uint256 stratTotalSupply = stratToken.totalSupply();
        uint256 adjustedCdtSupply = cdtToken.totalSupply() + (settlementEntitlementUsd_ / 2);

        // Avoid division by zero; bonding will fail its min-output checks if this returns 0.
        if (stratTotalSupply == 0 || totalEth == 0) {
            return (0, 0);
        }

        // Premium term is USD-denominated; pcf is scaled by SCALE.
        uint256 premiumUsd = (pcf * adjustedCdtSupply) / SCALE;
        // Apply GCF to GAV; gcf is scaled by SCALE.
        uint256 numeratorUsd = (gavUSD * gcf / SCALE) + premiumUsd; // Scale: 1e18 (USD)

        // USD-per-unit rates (scaled by 1e18), used to compute amounts from USD notionals.
        uint256 stratConversionRate = (numeratorUsd * SCALE) / stratTotalSupply; // USD per STRAT (1e18)
        stratAmount = settlementEntitlementUsd_ * SCALE / stratConversionRate;

        uint256 debtInEth = cdtToken.totalSupply() * _ETH_USD_ORACLE_SCALE / ethPriceUSD;
        if (debtInEth >= totalEth) {
            ethAmount = 0;
        } else {
            uint256 navETH = totalEth - debtInEth;
            uint256 ethConversionRate = (numeratorUsd * SCALE) / navETH;
            ethAmount = settlementEntitlementUsd_ * SCALE / ethConversionRate;
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (tokenURIRenderer != address(0)) {
            return TokenURIRenderer(tokenURIRenderer).render(tokenId);
        } else {
            return "";
        }
    }
}
