// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20, IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/**
 * @title The STRAT ETH Long Bonds Strategy
 * @dev convertible notes on STRAT. Bonders get CDT and a StratOption.
 */
contract StratETHLongBonds is Ownable2Step {
    // ===== EVENTS ===== //

    event UpdateBCV(uint256 newBcv);
    event LongBond(
        address indexed bonder,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 strikePrice,
        uint256 redemptionPrice,
        uint256 ethAmount,
        uint48 expiry,
        uint48 timelock
    );

    // ===== ERRORS ===== //

    error InvalidParams(string reason);

    // ===== CONSTANTS ===== //

    uint256 public constant SCALE = 1e18;

    // ===== STATE VARIABLES ===== //

    IERC20MintableBurnable public immutable cdtToken;
    IERC20 public immutable stratToken;
    IStratOptionMinter public immutable stratOption;
    address immutable treasuryManager;
    IOracle public immutable ethUsdOracle;
    IOracle public immutable stratEthOracle;
    uint256 public immutable USD_ORACLE_SCALE;

    uint256 public bcv;

    /**
     * @param _cdtToken The CDT token
     * @param _stratToken The STRAT token
     * @param _stratOption The STRAT option
     * @param _treasuryManager The treasury manager
     * @param _ethUsdOracle The ETH/USD oracle
     * @param _stratEthOracle The STRAT/ETH oracle
     * @param _bcv The bond conversion value, scaled by SCALE
     * @param owner The owner
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _stratOption,
        address _treasuryManager,
        address _ethUsdOracle,
        address _stratEthOracle,
        uint256 _bcv,
        address owner
    ) Ownable(owner) {
        cdtToken = IERC20MintableBurnable(_cdtToken);
        stratToken = IERC20(_stratToken);
        stratOption = IStratOptionMinter(_stratOption);
        treasuryManager = _treasuryManager;
        ethUsdOracle = IOracle(_ethUsdOracle);
        stratEthOracle = IOracle(_stratEthOracle);

        if (stratEthOracle.quoteTokenDecimals() != 18) revert InvalidParams("stratEthOracle");
        USD_ORACLE_SCALE = 10 ** ethUsdOracle.quoteTokenDecimals();

        bcv = _bcv;
    }

    function setBCV(uint256 _newBcv) external onlyOwner {
        bcv = _newBcv;
        emit UpdateBCV(_newBcv);
    }

    function bond(address bonder) external payable {
        if (msg.value == 0) revert InvalidParams("msg.value");

        uint256 ethUsdValue = msg.value * ethUsdOracle.price() / USD_ORACLE_SCALE; // Scale: 18 decimals
        uint256 currentStrikePrice = strikePrice(ethUsdValue); // Scale: 18 decimals
        uint256 optionQuantity = ethUsdValue * SCALE / currentStrikePrice; // Scale: 18 decimals

        uint48 expiry = uint48(block.timestamp + (4.2 * 365 days));
        uint48 timelock = uint48(block.timestamp + 69 minutes);

        uint256 tokenId = stratOption.mintFor(
            bonder, // Option owner
            optionQuantity, // Quantity of STRAT tokens that can be exercised
            currentStrikePrice, // Strike price: quantity of CDT per STRAT
            currentStrikePrice, // Redemption price: USD per STRAT option
            expiry, // Expiry: 4.2 years from now
            timelock // Timelock: 69 minutes from now
        );

        cdtToken.mint(bonder, ethUsdValue);

        // Send the eth to the treasury manager contract
        (bool success,) = treasuryManager.call{value: msg.value}("");
        require(success, "Transfer failed");

        emit LongBond(
            bonder, tokenId, optionQuantity, currentStrikePrice, currentStrikePrice, msg.value, expiry, timelock
        );
    }

    /// @notice Provides the strike price for a given USD value of ETH
    ///
    /// @param  notionalUSDAmount   The USD value of ETH to calculate the strike price for
    /// @return strikePrice_        The strike price, in terms of SCALE
    function strikePrice(uint256 notionalUSDAmount) public view returns (uint256 strikePrice_) {
        uint256 premium = bcv * (cdtToken.totalSupply() + (notionalUSDAmount / 2)) / stratToken.totalSupply();

        // No need to adjust the decimal scale of the STRAT-ETH oracle, since it is always 18 decimals
        strikePrice_ = stratEthOracle.price() * ethUsdOracle.price() / USD_ORACLE_SCALE + premium;
        return strikePrice_;
    }
}
