// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20, IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/**
 * @title The STRAT ETH Long Bonds Strategy
 * @dev convertible notes on STRAT. Bonders get cdUSD and a StratOption.
 */
contract StratETHLongBonds is Ownable2Step {
    IERC20MintableBurnable public immutable cdUSD;
    IERC20 public immutable stratToken;
    IStratOptionMinter public immutable stratOption;
    address immutable treasuryManager;
    IOracle public immutable ethUsdOracle;
    IOracle public immutable stratEthOracle;

    uint256 public bcv;

    uint256 public immutable SCALE = 1e6;

    // TODO(nap): Events

    constructor(
        address _cdUSD,
        address _stratToken,
        address _stratOption,
        address _treasuryManager,
        address _ethUsdOracle,
        address _stratEthOracle,
        uint256 _bcv,
        address owner
    ) Ownable(owner) {
        cdUSD = IERC20MintableBurnable(_cdUSD);
        stratToken = IERC20(_stratToken);
        stratOption = IStratOptionMinter(_stratOption);
        treasuryManager = _treasuryManager;
        ethUsdOracle = IOracle(_ethUsdOracle);
        stratEthOracle = IOracle(_stratEthOracle);

        bcv = _bcv;
    }

    function setBCV(uint256 _newBcv) external onlyOwner {
        bcv = _newBcv;
    }

    function bond(address bonder) external payable {
        require(msg.value > 0, "No ETH sent");

        // TODO: scaling factors
        uint256 notionalUSDAmount = msg.value * ethPrice();
        uint256 strikeAmount = notionalUSDAmount;
        uint256 notionalUnderlyingAmount = notionalUSDAmount * SCALE / strikePrice(notionalUSDAmount) / SCALE; // TODO(econ):
            // confirming scaling factors

        stratOption.mint(
            bonder,
            strikeAmount,
            notionalUnderlyingAmount,
            notionalUSDAmount,
            block.timestamp + (420 * 365 days),
            block.timestamp + 69 minutes
        );

        cdUSD.mint(bonder, notionalUSDAmount);

        // Send the eth to the treasury manager contract
        (bool success,) = treasuryManager.call{value: msg.value}("");
        require(success, "Transfer failed");
    }

    function strikePrice(uint256 notionalUSDAmount) public view returns (uint256) {
        // TODO(nap/econ): implement oracles and work out scaling factors

        uint256 ratio = ((cdUSD.totalSupply() + (notionalUSDAmount / 2)) * SCALE) / stratToken.totalSupply();
        uint256 debtToMc = (ratio * stratPrice()) / SCALE;
        return stratPrice() * bcv * debtToMc;
    }

    function stratPrice() public view returns (uint256) {
        // TODO(nap/econ): implement oracles and work out scaling factors
        return stratEthOracle.price() * ethUsdOracle.price() / 1e18;
    }

    function ethPrice() public view returns (uint256) {
        // TODO(nap/econ): implement oracles and work out scaling factors
        return ethUsdOracle.price() / 1e8;
    }
}
