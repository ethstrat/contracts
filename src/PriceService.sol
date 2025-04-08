// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {IPriceService} from "./interfaces/IPriceService.sol";
import {WETH, USD} from "./lib/PriceOracleConstants.sol";

/**
 * @title   PriceService
 * @dev     Service contract that provides price feeds for ETH/USD and STRAT/ETH using Euler price oracles.
 */
contract PriceService is IPriceService {
    IPriceOracle public immutable ethUsdOracle;
    IPriceOracle public immutable stratEthOracle;
    IERC20MintableBurnable public immutable strat;

    /**
     * @dev Can be pre-set as both wETH and USD have a scale of 18.
     */
    uint256 internal constant _ETH_USD_ORACLE_SCALE = 1e18;
    uint256 internal constant _STRAT_ETH_ORACLE_SCALE = 1e18;

    error EthUsdPriceInvalid();
    error StratEthPriceInvalid();
    error StratDecimalsInvalid();
    error ZeroAddress();

    constructor(address _ethUsdOracle, address _stratEthOracle, address _strat) {
        if (_ethUsdOracle == address(0)) revert ZeroAddress();
        if (_stratEthOracle == address(0)) revert ZeroAddress();
        if (_strat == address(0)) revert ZeroAddress();

        ethUsdOracle = IPriceOracle(_ethUsdOracle);
        stratEthOracle = IPriceOracle(_stratEthOracle);
        strat = IERC20MintableBurnable(_strat);

        // Validate that the STRAT token has a scale of 18
        if (strat.decimals() != 18) revert StratDecimalsInvalid();

        // Validate that the oracles are correct
        _getEthUsdPrice();
        _getStratEthPrice();
    }

    /**
     * @inheritdoc IPriceService
     */
    function getEthUsdPrice() external view override returns (uint256 price, uint256 scale) {
        return _getEthUsdPrice();
    }

    /**
     * @inheritdoc IPriceService
     */
    function getStratEthPrice() external view override returns (uint256 price, uint256 scale) {
        return _getStratEthPrice();
    }

    /**
     * @notice Internal function to get the price of ETH in USD.
     *
     * @return price The price of ETH in USD, with a scale of 18.
     * @return scale The scale of the price.
     */
    function _getEthUsdPrice() internal view returns (uint256 price, uint256 scale) {
        // Quantity of USD for 1 WETH
        // This will revert if the base or quote tokens are not as expected,
        // which would indicate that the incorrect IPriceOracle was provided.
        price = ethUsdOracle.getQuote(1e18, WETH, USD);
        scale = _ETH_USD_ORACLE_SCALE;

        // Revert if the price is not returned
        if (price == 0) revert EthUsdPriceInvalid();
    }

    /**
     * @notice Internal function to get the price of STRAT in ETH.
     *
     * @return price The price of STRAT in ETH, with a scale of 18.
     * @return scale The scale of the price.
     */
    function _getStratEthPrice() internal view returns (uint256 price, uint256 scale) {
        // Quantity of ETH for 1 STRAT
        // This will revert if the base or quote tokens are not as expected,
        // which would indicate that the incorrect IPriceOracle was provided.
        price = stratEthOracle.getQuote(1e18, address(strat), WETH);
        scale = _STRAT_ETH_ORACLE_SCALE;

        // Revert if the price is not returned
        if (price == 0) revert StratEthPriceInvalid();
    }
}
