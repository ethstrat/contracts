// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {EthUsdPriceFeedConsumer} from "./lib/EthUsdPriceFeedConsumer.sol";

import {IERC20, IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {IStratOption} from "./interfaces/IStratOption.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/**
 * @title The STRAT ETH Long Bonds Strategy
 * @dev convertible notes on STRAT. Bonders get CDT and a StratOption.
 */
contract StratETHLongBonds is Ownable2Step, EthUsdPriceFeedConsumer {
    IERC20MintableBurnable public immutable cdtToken;
    IERC20 public immutable stratToken;
    IStratOption public immutable stratOption;
    ITreasury public immutable treasury;
    address immutable treasuryVault;

    uint256 public pcf;
    uint256 public gcf;

    uint256 public constant SCALE = 1e18;

    event OwnerChangedPCF(uint256 oldVal, uint256 newVal);
    event OwnerChangedGCF(uint256 oldVal, uint256 newVal);

    event LongBond(
        address indexed bonder,
        uint256 strike,
        uint256 notionalUnderlyingAmount,
        uint256 notionalUSDAmount,
        uint256 ethAmount,
        uint256 expiry,
        uint256 timelock
    );

    error NoEthSent();
    error ZeroAddress();
    error EthTransferFailed();
    error TransactionStale(uint256 deadline);
    error InsufficientOutput(uint256 minNotionalUnderlyingAmount, uint256 notionalUnderlyingAmount);

    /**
     * @param _cdtToken The CDT token
     * @param _stratToken The STRAT token
     * @param _stratOption The STRAT option
     * @param _treasury operations on treasury
     * @param _treasuryVault vault where bonded ETH is sent
     * @param _ethUsdOracle The ETH/USD oracle
     * @param _pcf scaling factor applied on the debt ratio when deciding the bond conversion value (scaled by SCALE)
     * @param _gcf scaling factor applied on the gav baseline when deciding the bond conversion value (scaled by SCALE)
     * @param owner The owner
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _stratOption,
        address _treasury,
        address _treasuryVault,
        address _ethUsdOracle,
        uint256 _pcf,
        uint256 _gcf,
        address owner
    ) Ownable(owner) EthUsdPriceFeedConsumer(_ethUsdOracle) {
        cdtToken = IERC20MintableBurnable(_cdtToken);
        stratToken = IERC20(_stratToken);
        stratOption = IStratOption(_stratOption);
        treasury = ITreasury(_treasury);
        treasuryVault = _treasuryVault;

        pcf = _pcf;
        gcf = _gcf;
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
     * @notice Updates the GCF (Gropss asset Value(GAV) Control Factor) to the new specified value.
     * @dev This function can only be called by the contract owner.
     * @param newVal The new value to set for the GCF.
     */
    function setGCF(uint256 newVal) external onlyOwner {
        emit OwnerChangedGCF(gcf, newVal);
        gcf = newVal;
    }

    function bond(address bonder, uint256 minNotionalUnderlyingAmount, uint256 deadline) external payable {
        if (msg.value == 0) revert NoEthSent();
        if (bonder == address(0)) revert ZeroAddress();
        if (deadline < block.timestamp) revert TransactionStale(deadline);

        // redemption
        uint256 notionalUSDAmount = msg.value * _getEthUsdPrice() / _ETH_USD_ORACLE_SCALE; // Scale: 18 decimals
        uint256 strikeAmount = notionalUSDAmount; // Scale: 18 decimals
        uint256 notionalUnderlyingAmount = notionalUSDAmount * SCALE / strikePrice(notionalUSDAmount); // Scale: 18
            // decimals (since strikePrice is always 18 decimals)

        // Check that the notional underlying amount is greater than the minimum
        if (notionalUnderlyingAmount < minNotionalUnderlyingAmount) {
            revert InsufficientOutput(minNotionalUnderlyingAmount, notionalUnderlyingAmount);
        }

        stratOption.mint(
            bonder, // Option owner
            strikeAmount, // Strike amount: amount of CDT to be burned to exercise the option
            notionalUnderlyingAmount, // Notional underlying amount: amount of STRAT that will be received if the option
                // is exercised
            notionalUSDAmount, // Notional USD amount: USD value of the ETH that was deposited at the time of minting
            block.timestamp + (4.2 * 365 days), // Expiry: 4.2 years from now
            block.timestamp + 6.9 days // Timelock: 6.9 days from now
        );

        cdtToken.mint(bonder, notionalUSDAmount);

        // Send the eth to the treasury manager contract
        (bool success,) = treasuryVault.call{value: msg.value}("");
        if (!success) revert EthTransferFailed();

        emit LongBond(
            bonder,
            strikeAmount,
            notionalUnderlyingAmount,
            notionalUSDAmount,
            msg.value,
            block.timestamp + (4.2 * 365 days),
            block.timestamp + 6.9 days
        );
    }

    /// @notice Provides the strike price for a given USD value of ETH
    ///
    /// @param  notionalUSDAmount   The USD value of ETH to calculate the strike price for
    /// @return strikePrice_        The strike price, in terms of SCALE
    function strikePrice(uint256 notionalUSDAmount) public view returns (uint256 strikePrice_) {
        uint256 gav = treasury.total() * _getEthUsdPrice() / _ETH_USD_ORACLE_SCALE;

        uint256 stratTotalSupply = stratToken.totalSupply();
        uint256 adjustedCdtSupply = (cdtToken.totalSupply() + (notionalUSDAmount / 2));

        strikePrice_ = ((gav * gcf) + (pcf * adjustedCdtSupply)) / stratTotalSupply;
    }
}
