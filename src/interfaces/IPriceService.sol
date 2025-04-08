// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

interface IPriceService {
    /**
     * @notice Get the price of ETH in USD.
     *
     * @return price The price of ETH in USD, with a scale of 18.
     * @return scale The scale of the price.
     */
    function getEthUsdPrice() external view returns (uint256 price, uint256 scale);

    /**
     * @notice Get the price of STRAT in ETH.
     *
     * @return price The price of STRAT in ETH, with a scale of 18.
     * @return scale The scale of the price.
     */
    function getStratEthPrice() external view returns (uint256 price, uint256 scale);
}
