pragma solidity ^0.8.0;

interface IOracle {
    /**
     * @notice Get the price of an asset, scaled by 1e8
     */
    function price() external view returns (uint256);
}
