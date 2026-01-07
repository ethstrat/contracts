// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {EthUsdPriceFeedConsumer} from "./lib/EthUsdPriceFeedConsumer.sol";
import {TokenURIRenderer} from "./interfaces/TokenURIRenderer.sol";

import {IERC20, IERC20MintableBurnable, IERC20MintableBurnablePermit} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {Permit} from "./lib/Permit.sol";

/**
 * @title The ETH Strategy Long Bonds
 * @dev NFT-based convertible notes on STRAT. Bonders get CDT and an NFT representing the option.
 */
contract EthStrategyLongBonds is ERC721, Ownable2Step, EthUsdPriceFeedConsumer {
    using Permit for IERC20MintableBurnablePermit;

    uint256 public _tokenIdCounter;

    IERC20MintableBurnablePermit public immutable cdtToken;
    IERC20MintableBurnable public immutable stratToken;
    IERC20 public immutable gavToken; // Token used for GAV calculation (replaces ITreasury.total())
    address immutable treasuryVault;
    address immutable treasury; // Treasury contract for withdrawals (has withdraw function)

    uint256 public pcf;
    uint256 public gcf;

    uint256 public constant SCALE = 1e18;

    address public tokenURIRenderer;

    /// @notice The amount of CDT required to exercise the option
    /// @dev    Scale: SCALE
    mapping(uint256 tokenId => uint256) public strikeAmount;

    /// @notice The amount of STRAT that will be received if the option is exercised
    /// @dev    Scale: SCALE
    mapping(uint256 tokenId => uint256) public notionalUnderlyingAmount;

    /// @notice The USD value of the ETH that was deposited, at the moment the user bonds
    /// @dev    Scale: SCALE
    mapping(uint256 tokenId => uint256) public notionalUSDAmount;

    /// @notice The timestamp at which the option expires
    mapping(uint256 tokenId => uint256) public expiry;

    /// @notice The timestamp at which the option can be exercised
    mapping(uint256 tokenId => uint256) public timelock;

    event OwnerChangedPCF(uint256 oldVal, uint256 newVal);
    event OwnerChangedGCF(uint256 oldVal, uint256 newVal);
    event RendererUpdated(address indexed renderer);

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

    event OptionExercised(address indexed optionOwner, uint256 indexed tokenId, uint256 strike, uint256 strat);
    event OptionRedeemed(address indexed optionOwner, uint256 indexed tokenId, uint256 notionalUSDAmount, uint256 ethAmount);

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

    /**
     * @param _cdtToken The CDT token
     * @param _stratToken The STRAT token
     * @param _gavToken Token used for GAV calculation (replaces ITreasury.total())
     * @param _treasuryVault vault where bonded ETH is sent
     * @param _treasury Treasury contract for withdrawals (has withdraw function)
     * @param _ethUsdOracle The ETH/USD oracle
     * @param _pcf scaling factor applied on the debt ratio when deciding the bond conversion value (scaled by SCALE)
     * @param _gcf scaling factor applied on the gav baseline when deciding the bond conversion value (scaled by SCALE)
     * @param owner The owner
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _gavToken,
        address _treasuryVault,
        address _treasury,
        address _ethUsdOracle,
        uint256 _pcf,
        uint256 _gcf,
        address owner
    ) ERC721("ETH Strategy Long Bond", "esLB") Ownable(owner) EthUsdPriceFeedConsumer(_ethUsdOracle) {
        cdtToken = IERC20MintableBurnablePermit(_cdtToken);
        stratToken = IERC20MintableBurnable(_stratToken);
        gavToken = IERC20(_gavToken);
        treasuryVault = _treasuryVault;
        treasury = _treasury;

        pcf = _pcf;
        gcf = _gcf;
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
     * @notice Updates the GCF (Gross asset Value(GAV) Control Factor) to the new specified value.
     * @dev This function can only be called by the contract owner.
     * @param newVal The new value to set for the GCF.
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

    function bond(address bonder, uint256 minNotionalUnderlyingAmount, uint256 deadline) external payable {
        if (msg.value == 0) revert NoEthSent();
        if (bonder == address(0)) revert ZeroAddress();
        if (deadline < block.timestamp) revert TransactionStale(deadline);

        // redemption
        uint256 notionalUSD = msg.value * _getEthUsdPrice() / _ETH_USD_ORACLE_SCALE; // Scale: 18 decimals
        uint256 strikeAmount_ = notionalUSD; // Scale: 18 decimals
        uint256 notionalUnderlyingAmount_ = notionalUSD * SCALE / strikePrice(notionalUSD); // Scale: 18
            // decimals (since strikePrice is always 18 decimals)

        // Check that the notional underlying amount is greater than the minimum
        if (notionalUnderlyingAmount_ < minNotionalUnderlyingAmount) {
            revert InsufficientOutput(minNotionalUnderlyingAmount, notionalUnderlyingAmount_);
        }

        uint256 tokenId = _tokenIdCounter++;
        uint256 expiry_ = block.timestamp + (4.2 * 365 days);
        uint256 timelock_ = block.timestamp + 6.9 days;

        // Validate timelock and expiry
        if (block.timestamp > timelock_ || timelock_ > expiry_) {
            revert InvalidTimelockOrExpiry(timelock_, expiry_);
        }

        // Mint NFT
        _safeMint(bonder, tokenId);
        strikeAmount[tokenId] = strikeAmount_;
        notionalUnderlyingAmount[tokenId] = notionalUnderlyingAmount_;
        notionalUSDAmount[tokenId] = notionalUSD;
        expiry[tokenId] = expiry_;
        timelock[tokenId] = timelock_;

        cdtToken.mint(bonder, notionalUSD);

        // Send the eth to the treasury manager contract
        (bool success,) = treasuryVault.call{value: msg.value}("");
        if (!success) revert EthTransferFailed();

        emit LongBond(
            bonder,
            tokenId,
            strikeAmount_,
            notionalUnderlyingAmount_,
            notionalUSD,
            msg.value,
            expiry_,
            timelock_
        );
    }

    /**
     * @notice Exercises an option if it is not under a timelock and not expired, using an ERC-2612 permit.
     *
     * @param tokenId The identifier of the option token to exercise.
     * @param cdtPermitApproval The permit approval for the CDT tokens.
     */
    function exerciseWithPermit(uint256 tokenId, Permit.IPermitApproval memory cdtPermitApproval) public {
        // Check that the timelock period has passed.
        if (timelock[tokenId] > block.timestamp) {
            revert TimelockActive(msg.sender, tokenId);
        }

        // Ensure the option has not expired.
        if (expiry[tokenId] < block.timestamp) {
            revert OptionExpired(msg.sender, tokenId);
        }

        // Retrieve the owner of the option token.
        address optionOwner = ownerOf(tokenId);

        // Check that the sender is either the owner or approved for the option token.
        if (msg.sender != optionOwner && !isApprovedForAll(optionOwner, msg.sender)) {
            revert NotOwnerOrApproved(msg.sender, tokenId);
        }

        // Retrieve strike and underlying amounts.
        uint256 strike = strikeAmount[tokenId];
        uint256 strat = notionalUnderlyingAmount[tokenId];

        // Burn the corresponding amount from the sender
        cdtToken.validatePermit(msg.sender, address(this), strike, cdtPermitApproval);
        cdtToken.burnFrom(msg.sender, strike);

        // Clear the option data
        strikeAmount[tokenId] = 0;
        notionalUnderlyingAmount[tokenId] = 0;
        notionalUSDAmount[tokenId] = 0;
        expiry[tokenId] = 0;
        timelock[tokenId] = 0;

        // Burn the NFT
        _burn(tokenId);

        // Mint the underlying token for the option owner.
        uint256 premintedStratBalance = stratToken.balanceOf(address(this));
        if (premintedStratBalance < strat) {
            // Mint the required amount of STRAT tokens to this contract.
            stratToken.mint(address(this), strat - premintedStratBalance);
        }
        stratToken.transfer(optionOwner, strat);

        // Emit event on successful exercise.
        emit OptionExercised(optionOwner, tokenId, strike, strat);
    }

    /**
     * @notice Exercises an option if it is not under a timelock and not expired.
     *
     * @param tokenId The identifier of the option token to exercise.
     */
    function exercise(uint256 tokenId) external {
        exerciseWithPermit(tokenId, Permit.getEmptyApproval());
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
    /// @param cdtPermitApproval    The permit approval for the CDT tokens
    function redeemCdtForUsdNotionalWithPermit(uint256 tokenId, Permit.IPermitApproval memory cdtPermitApproval)
        public
    {
        if (timelock[tokenId] > block.timestamp) revert TimelockActive(msg.sender, tokenId);
        if (expiry[tokenId] > block.timestamp) revert OptionUnexpired(msg.sender, tokenId);

        uint256 notionalUSDAmount_ = notionalUSDAmount[tokenId];
        uint256 totalDebt = cdtToken.totalSupply();
        uint256 ethPriceUSD = _getEthUsdPrice();
        uint256 treasuryInETH = address(treasury).balance;
        uint256 treasuryInUSD = treasuryInETH * ethPriceUSD / _ETH_USD_ORACLE_SCALE;
        address optionOwner = ownerOf(tokenId);

        // Check the caller is either the option owner, or operator
        if (msg.sender != optionOwner && !isApprovedForAll(optionOwner, msg.sender)) {
            revert NotOwnerOrApproved(msg.sender, tokenId);
        }

        // Burn CDT
        cdtToken.validatePermit(msg.sender, address(this), notionalUSDAmount_, cdtPermitApproval);

        uint256 ethAmount = 0;
        if (treasuryInUSD > cdtToken.totalSupply()) {
            ethAmount = notionalUSDAmount_ * _ETH_USD_ORACLE_SCALE / ethPriceUSD;
        } else {
            ethAmount = notionalUSDAmount_ * treasuryInETH / totalDebt;
        }

        // Clear the option data
        strikeAmount[tokenId] = 0;
        notionalUnderlyingAmount[tokenId] = 0;
        notionalUSDAmount[tokenId] = 0;
        expiry[tokenId] = 0;
        timelock[tokenId] = 0;

        // Burn the NFT
        _burn(tokenId);

        // Burn CDT
        cdtToken.burnFrom(msg.sender, notionalUSDAmount_);

        // Withdraw ETH from treasury
        (bool success,) = treasury.call(
            abi.encodeWithSignature("withdraw(uint256,address)", ethAmount, optionOwner)
        );
        if (!success) revert EthTransferFailed();

        emit OptionRedeemed(optionOwner, tokenId, notionalUSDAmount_, ethAmount);
    }

    /// @notice Redeem option and CDT tokens for the USD notional value post option expiry, paid
    //          back in ETH
    /// @dev    This is the same as {redeemCdtForUsdNotionalWithPermit}, but without the permit approval
    ///
    /// @param tokenId  The ID of the option to redeem
    function redeemCdtForUsdNotional(uint256 tokenId) external {
        redeemCdtForUsdNotionalWithPermit(tokenId, Permit.getEmptyApproval());
    }

    /// @notice Provides the strike price for a given USD value of ETH
    ///
    /// @param  notionalUSD   The USD value of ETH to calculate the strike price for
    /// @return strikePrice_        The strike price, in terms of SCALE
    function strikePrice(uint256 notionalUSD) public view returns (uint256 strikePrice_) {
        uint256 gav = gavToken.totalSupply() * _getEthUsdPrice() / _ETH_USD_ORACLE_SCALE;

        uint256 stratTotalSupply = stratToken.totalSupply();
        uint256 adjustedCdtSupply = (cdtToken.totalSupply() + (notionalUSD / 2));

        strikePrice_ = ((gav * gcf) + (pcf * adjustedCdtSupply)) / stratTotalSupply;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (tokenURIRenderer != address(0)) {
            return TokenURIRenderer(tokenURIRenderer)
                .render(
                    tokenId,
                    strikeAmount[tokenId],
                    notionalUnderlyingAmount[tokenId],
                    notionalUSDAmount[tokenId],
                    expiry[tokenId],
                    timelock[tokenId]
                );
        } else {
            return "";
        }
    }
}

