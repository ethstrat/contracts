// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IPriceService} from "./interfaces/IPriceService.sol";

import {IERC20MintableBurnable, IERC20MintableBurnablePermit} from "./interfaces/IERC20.sol";
import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";
import {Permit} from "./lib/Permit.sol";

/**
 * @title The STRAT ETH Long Bonds Strategy
 * @dev convertible notes on STRAT. Bonders get CDT and a StratOption.
 */
contract StratETHShortBonds is Ownable2Step {
    using Permit for IERC20MintableBurnablePermit;

    IERC20MintableBurnablePermit public immutable cdtToken;
    IERC20MintableBurnable public immutable stratToken;
    IStratOptionMinter public immutable stratOption;
    address public immutable bondConverter;
    IPriceService public priceService;

    uint256 public bcv;

    uint256 public constant SCALE = 1e18;

    event UpdateBCV(uint256 newBcv);
    event ShortBond(address indexed bonder, uint256 cdt, uint256 strat, uint256 expiry, uint256 timelock);
    event PriceServiceUpdated(address indexed oldPriceService, address indexed newPriceService);

    error ZeroAddress();

    /**
     * @param _cdtToken The CDT token
     * @param _stratToken The STRAT token
     * @param _stratOption The STRAT option
     * @param _priceService The price service
     * @param _bondConverter The bond converter address
     * @param _bcv The bond conversion value, scaled by SCALE
     * @param owner The owner
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _stratOption,
        address _priceService,
        address _bondConverter,
        uint256 _bcv,
        address owner
    ) Ownable(owner) {
        if (_cdtToken == address(0)) revert ZeroAddress();
        if (_stratToken == address(0)) revert ZeroAddress();
        if (_stratOption == address(0)) revert ZeroAddress();
        if (_priceService == address(0)) revert ZeroAddress();
        if (_bondConverter == address(0)) revert ZeroAddress();

        cdtToken = IERC20MintableBurnablePermit(_cdtToken);
        stratToken = IERC20MintableBurnable(_stratToken);
        stratOption = IStratOptionMinter(_stratOption);
        bondConverter = _bondConverter;
        priceService = IPriceService(_priceService);

        bcv = _bcv;
    }

    function setBCV(uint256 _newBcv) external onlyOwner {
        bcv = _newBcv;
        emit UpdateBCV(_newBcv);
    }

    function setPriceService(address _newPriceService) external onlyOwner {
        if (_newPriceService == address(0)) revert ZeroAddress();

        address oldPriceService = address(priceService);
        priceService = IPriceService(_newPriceService);

        emit PriceServiceUpdated(oldPriceService, _newPriceService);
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
        (uint256 stratEthPrice, uint256 stratEthPriceScale) = priceService.getStratEthPrice();
        (uint256 ethUsdPrice,) = priceService.getEthUsdPrice();
        uint256 stratUsdPrice = stratEthPrice * ethUsdPrice / stratEthPriceScale;
        //TODO(nap): Do we neeed to price by taking into account the expected cdt burn?
        return stratUsdPrice * stratToken.totalSupply() / (cdtToken.totalSupply() - (notionalUSDAmount / 2)) * bcv
            * stratUsdPrice / SCALE / SCALE;
    }
}
