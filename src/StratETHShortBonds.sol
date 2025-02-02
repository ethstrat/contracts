// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20, IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";
import {IOracle} from "./interfaces/IOracle.sol";

import "forge-std/console.sol";

/**
 * @title The STRAT ETH Long Bonds Strategy
 * @dev convertible notes on STRAT. Bonders get CDT and a StratOption.
 */
contract StratETHShortBonds is Ownable2Step {
    IERC20MintableBurnable public immutable cdtToken;
    IERC20 public immutable stratToken;
    IStratOptionMinter public immutable stratOption;
    IOracle public immutable ethUsdOracle;
    IOracle public immutable stratEthOracle;

    uint256 public bcv;

    uint256 public immutable SCALE = 1e18;
    uint256 public immutable USD_ORACLE_SCALE;

    // TODO(nap): Events

    /**
     * @param _cdtToken The CDT token
     * @param _stratToken The STRAT token
     * @param _stratOption The STRAT option
     * @param _ethUsdOracle The ETH/USD oracle
     * @param _stratEthOracle The STRAT/ETH oracle
     * @param _bcv The bond conversion value, scaled by SCALE
     * @param owner The owner
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _stratOption,
        address _ethUsdOracle,
        address _stratEthOracle,
        uint256 _bcv,
        address owner
    ) Ownable(owner) {
        cdtToken = IERC20MintableBurnable(_cdtToken);
        stratToken = IERC20(_stratToken);
        stratOption = IStratOptionMinter(_stratOption);
        ethUsdOracle = IOracle(_ethUsdOracle);
        stratEthOracle = IOracle(_stratEthOracle);

        USD_ORACLE_SCALE = 10 ** ethUsdOracle.quoteTokenDecimals();
        require(stratEthOracle.quoteTokenDecimals() == 18, "StratEthOracle must have 18 decimals");

        bcv = _bcv;
    }

    function setBCV(uint256 _newBcv) external onlyOwner {
        bcv = _newBcv;
    }

    function bond(address bonder, uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        uint256 notionalUnderlyingAmount = amount * SCALE / strikePrice(amount);

        stratOption.mint(
            bonder, 0, notionalUnderlyingAmount, 0, block.timestamp + (420 * 365 days), block.timestamp + 69 minutes
        );

        cdtToken.burnFrom(msg.sender, amount);
    }

    function strikePrice(uint256 notionalUSDAmount) public view returns (uint256) {
        uint256 stratPrice = stratEthOracle.price() * ethUsdOracle.price() / USD_ORACLE_SCALE;
        //TODO(nap): Do we neeed to price by taking into account the expected cdt burn?
        return stratPrice * stratToken.totalSupply() / (cdtToken.totalSupply() - (notionalUSDAmount / 2)) * bcv
            * stratPrice / SCALE / SCALE;
    }
}
