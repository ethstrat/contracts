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

        // redemption
        uint256 notionalUSDAmount = msg.value * ethUsdOracle.price() / USD_ORACLE_SCALE; // Scale: 18 decimals
        uint256 strikeAmount = notionalUSDAmount; // Scale: 18 decimals
        uint256 notionalUnderlyingAmount = notionalUSDAmount * SCALE / strikePrice(notionalUSDAmount); // Scale: 18
            // decimals (since strikePrice is always 18 decimals)

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
        uint256 gav = treasury.total() * ethUsdOracle.price() / USD_ORACLE_SCALE;

        uint256 stratTotalSupply = stratToken.totalSupply();
        uint256 adjustedCdtSupply = (cdtToken.totalSupply() + (notionalUSDAmount / 2));

        strikePrice_ = ((gav * SCALE) + (bcv * adjustedCdtSupply)) / stratTotalSupply;
        return strikePrice_;
    }
}
