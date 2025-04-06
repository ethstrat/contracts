// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {MintableBurnableToken} from "./MintableBurnableToken.sol";
import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {Permit} from "./lib/Permit.sol";

/**
 * @title The STRAT ETH Long Bonds Strategy
 * @dev convertible notes on STRAT. Bonders get CDT and a StratOption.
 */
contract StratETHShortBonds is Ownable2Step {
    using Permit for MintableBurnableToken;

    MintableBurnableToken public immutable cdtToken;
    MintableBurnableToken public immutable stratToken;
    IStratOptionMinter public immutable stratOption;
    IOracle public immutable ethUsdOracle;
    IOracle public immutable stratEthOracle;
    address public immutable bondConverter;

    uint256 public bcv;

    uint256 public immutable SCALE = 1e18;
    uint256 public immutable USD_ORACLE_SCALE;

    event UpdateBCV(uint256 newBcv);
    event ShortBond(address indexed bonder, uint256 cdt, uint256 strat, uint256 expiry, uint256 timelock);

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
        address _bondConverter,
        uint256 _bcv,
        address owner
    ) Ownable(owner) {
        cdtToken = MintableBurnableToken(_cdtToken);
        stratToken = MintableBurnableToken(_stratToken);
        stratOption = IStratOptionMinter(_stratOption);
        ethUsdOracle = IOracle(_ethUsdOracle);
        stratEthOracle = IOracle(_stratEthOracle);
        bondConverter = _bondConverter;

        USD_ORACLE_SCALE = 10 ** ethUsdOracle.quoteTokenDecimals();
        require(stratEthOracle.quoteTokenDecimals() == 18, "StratEthOracle must have 18 decimals");

        bcv = _bcv;
    }

    function setBCV(uint256 _newBcv) external onlyOwner {
        bcv = _newBcv;
        emit UpdateBCV(_newBcv);
    }

    function bondWithPermit(address bonder, uint256 amount, Permit.IPermitApproval memory cdtPermitApproval) public {
        require(amount > 0, "Amount must be greater than 0");
        uint256 notionalUnderlyingAmount = amount * SCALE / strikePrice(amount);

        stratOption.mint(
            bonder, 0, notionalUnderlyingAmount, 0, block.timestamp + (420 * 365 days), block.timestamp + 6.9 days
        );

        cdtToken.validatePermit(msg.sender, address(this), amount, cdtPermitApproval);
        cdtToken.burnFrom(msg.sender, amount);
        stratToken.mint(bondConverter, notionalUnderlyingAmount);

        emit ShortBond(
            bonder, amount, notionalUnderlyingAmount, block.timestamp + (420 * 365 days), block.timestamp + 6.9 days
        );
    }

    function bond(address bonder, uint256 amount) external {
        bondWithPermit(bonder, amount, Permit.getEmptyApproval());
    }

    function strikePrice(uint256 notionalUSDAmount) public view returns (uint256) {
        uint256 stratPrice = stratEthOracle.price() * ethUsdOracle.price() / USD_ORACLE_SCALE;
        //TODO(nap): Do we neeed to price by taking into account the expected cdt burn?
        return stratPrice * stratToken.totalSupply() / (cdtToken.totalSupply() - (notionalUSDAmount / 2)) * bcv
            * stratPrice / SCALE / SCALE;
    }
}
