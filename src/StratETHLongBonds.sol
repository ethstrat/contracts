// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20, IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

import "forge-std/console.sol";

/**
 * @title The STRAT ETH Long Bonds Strategy
 * @dev convertible notes on STRAT. Bonders get CDT and a StratOption.
 */
contract StratETHLongBonds is Ownable2Step {
    IERC20MintableBurnable public immutable cdtToken;
    IERC20 public immutable stratToken;
    IStratOptionMinter public immutable stratOption;
    ITreasury public immutable treasury;
    address immutable treasuryVault;
    IOracle public immutable ethUsdOracle;

    uint256 public bcv;

    uint256 public immutable SCALE = 1e18;
    uint256 public immutable USD_ORACLE_SCALE;

    event UpdateBCV(uint256 newBcv);
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

    /**
     * @param _cdtToken The CDT token
     * @param _stratToken The STRAT token
     * @param _stratOption The STRAT option
     * @param _treasury operations on treasury
     * @param _treasuryVault vault where bonded ETH is sent
     * @param _ethUsdOracle The ETH/USD oracle
     * @param _bcv The bond conversion value, scaled by SCALE
     * @param owner The owner
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _stratOption,
        address _treasury,
        address _treasuryVault,
        address _ethUsdOracle,
        uint256 _bcv,
        address owner
    ) Ownable(owner) {
        cdtToken = IERC20MintableBurnable(_cdtToken);
        stratToken = IERC20(_stratToken);
        stratOption = IStratOptionMinter(_stratOption);
        treasury = ITreasury(_treasury);
        treasuryVault = _treasuryVault;
        ethUsdOracle = IOracle(_ethUsdOracle);

        USD_ORACLE_SCALE = 10 ** ethUsdOracle.quoteTokenDecimals();

        bcv = _bcv;
    }

    function setBCV(uint256 _newBcv) external onlyOwner {
        bcv = _newBcv;
        emit UpdateBCV(_newBcv);
    }

    function bond(address bonder) external payable {
        if (msg.value == 0) revert NoEthSent();
        if (bonder == address(0)) revert ZeroAddress();

        uint256 notionalUSDAmount = msg.value * ethUsdOracle.price() / USD_ORACLE_SCALE;
        uint256 strikeAmount = notionalUSDAmount;
        uint256 notionalUnderlyingAmount = notionalUSDAmount * SCALE / strikePrice(notionalUSDAmount);

        stratOption.mint(
            bonder,
            strikeAmount,
            notionalUnderlyingAmount,
            notionalUSDAmount,
            block.timestamp + (4.2 * 365 days),
            block.timestamp + 6.9 days
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

    function strikePrice(uint256 notionalUSDAmount) public view returns (uint256) {
        uint256 gav = treasury.total() * ethUsdOracle.price() / USD_ORACLE_SCALE;

        uint256 stratTotalSupply = stratToken.totalSupply();
        uint256 adjustedCdtSupply = (cdtToken.totalSupply() + (notionalUSDAmount / 2));

        return ((gav * SCALE) + (bcv * adjustedCdtSupply)) / stratTotalSupply;
    }
}
