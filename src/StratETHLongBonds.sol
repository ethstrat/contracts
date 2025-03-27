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
    IERC20MintableBurnable public immutable cdtToken;
    IERC20 public immutable stratToken;
    IStratOptionMinter public immutable stratOption;
    address immutable treasuryManager;
    IOracle public immutable ethUsdOracle;
    IOracle public immutable stratEthOracle;

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

        USD_ORACLE_SCALE = 10 ** ethUsdOracle.quoteTokenDecimals();
        require(stratEthOracle.quoteTokenDecimals() == 18, "StratEthOracle must have 18 decimals");

        bcv = _bcv;
    }

    function setBCV(uint256 _newBcv) external onlyOwner {
        bcv = _newBcv;
        emit UpdateBCV(_newBcv);
    }

    function bond(address bonder) external payable {
        require(msg.value > 0, "No ETH sent");

        // TODO note that the underlying USD amount is based on the ETH price at the time of bonding, affects later
        // redemption
        uint256 notionalUSDAmount = msg.value * ethUsdOracle.price() / USD_ORACLE_SCALE; // Scale: 18 decimals
        uint256 strikeAmount = notionalUSDAmount; // Scale: 18 decimals
        uint256 notionalUnderlyingAmount = notionalUSDAmount * SCALE / strikePrice(notionalUSDAmount); // TODO check
            // scale, as STRAT is 18 decimals

        stratOption.mint(
            bonder, // Option owner
            strikeAmount, // Strike amount: amount of CDT to be burned to exercise the option
            notionalUnderlyingAmount, // Notional underlying amount: amount of STRAT that will be received if the option
                // is exercised
            notionalUSDAmount, // Notional USD amount: USD value of the ETH that was deposited
            block.timestamp + (4.2 * 365 days), // Expiry: 4.2 years from now
            block.timestamp + 69 minutes // Timelock: 69 minutes from now
        );

        cdtToken.mint(bonder, notionalUSDAmount); // TODO check scale, since this is always 18 decimals

        // Send the eth to the treasury manager contract
        (bool success,) = treasuryManager.call{value: msg.value}("");
        require(success, "Transfer failed");

        emit LongBond(
            bonder,
            strikeAmount,
            notionalUnderlyingAmount,
            notionalUSDAmount,
            msg.value,
            block.timestamp + (4.2 * 365 days),
            block.timestamp + 69 minutes
        );
    }

    function strikePrice(uint256 notionalUSDAmount) public view returns (uint256) {
        uint256 premium = bcv * (cdtToken.totalSupply() + (notionalUSDAmount / 2)) / stratToken.totalSupply();
        return stratEthOracle.price() * ethUsdOracle.price() / USD_ORACLE_SCALE + premium;
    }
}
