// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IMorphoBase, MarketParams} from "../MorphoMoneyMarket/IMorpho.sol";
import {IERC20MintableBurnable} from "../interfaces/IERC20.sol";
import {StratOption} from "../StratOption.sol";
import {GhostStratToken} from "./GhostStratToken.sol";
import {DepositReceipt} from "./DepositReceipt.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

// @title A proxy that mints ghostStrat from an Option and CDT allowing
// borrow from the market.

contract MorphoStratBorrowProxy is Ownable {
    IMorphoBase public immutable morpho;
    IERC20MintableBurnable public immutable CDT;
    StratOption public immutable stratOption;
    IERC20MintableBurnable public immutable stratToken;
    GhostStratToken public immutable ghostStratToken;
    DepositReceipt public immutable depositReceipt;

    mapping(uint256 => address) public depositOwners;
    mapping(address => uint256) public depositedCDT;
    mapping(address => uint256) public depositedOption;

    constructor(
        address _morpho,
        address _cdt,
        address _stratOption,
        address _stratToken,
        address _ghostStratToken,
        address _depositReceipt,
        address _owner
    ) Ownable(_owner) {
        morpho = IMorphoBase(_morpho);
        CDT = IERC20MintableBurnable(_cdt);
        stratOption = StratOption(_stratOption);
        stratToken = IERC20MintableBurnable(_stratToken);
        ghostStratToken = GhostStratToken(_ghostStratToken);
        depositReceipt = DepositReceipt(_depositReceipt);

        // Approve the Morpho contract to spend ghostStrat tokens from this contract.
        ghostStratToken.approve(address(morpho), type(uint256).max);

    }

    function depositAndBorrow(uint256 cdtAmount, uint256 optionId, uint256 borrowAmount) external {
        // _deposit now returns the computed ghost strat value.
        uint256 ghostStrat = _deposit(msg.sender, cdtAmount, optionId);
        // Supply the minted ghost strat tokens as collateral to Morpho.
        _supplyCollateral(msg.sender, ghostStrat);

        _borrow(msg.sender, borrowAmount);
        // Optionally, you could use ghostStrat for additional logic here.
    }

    function _deposit(address user, uint256 cdtAmount, uint256 optionId) private returns (uint256) {
        
        require(depositedOption[user] == 0, "Option already deposited");
        // Transfer CDT from the user to the contract.
        CDT.transferFrom(user, address(this), cdtAmount);
        depositedCDT[user] += cdtAmount;

        // Transfer the single option from the user to the contract.
        depositedOption[user] = optionId;
        stratOption.transferFrom(user, address(this), optionId);

        // Compute the collateral value based on deposited CDT and option.
        uint256 ghostStrat = computeGhostStrat(user);
        // Mint ghost strat tokens to this contract.
        ghostStratToken.mint(address(this), ghostStrat);

        // Mint the deposit receipt NFT.
        uint256 depositId = depositReceipt.mint(user, cdtAmount, optionId);
        // Record the owner of the deposit.
        depositOwners[depositId] = user;

        // Return the computed ghost strat value.
        return ghostStrat;
    }

    function _supplyCollateral(address user, uint256 assetAmount) private {
        uint256 ghostStrat = computeGhostStrat(user);
        require(assetAmount <= ghostStrat, "Exceeds max GhostStrat amount");

        // Prepare the market parameters.
        MarketParams memory marketParams = MarketParams({
            loanToken: address(stratToken),
            collateralToken: address(ghostStratToken),
            oracle: address(0),
            irm: address(0),
            lltv: 90
        });
        // Supply the ghost strat tokens to the Morpho pool.
        // Here, we assume assetAmount represents the number of collateral tokens to supply.
        // Adjust the shares parameter if needed (using 0 for shares means asset-based supply).
        (uint256 assetsSupplied, uint256 sharesSupplied) = morpho.supply(
            marketParams,
            assetAmount, // assets being supplied as collateral
            0,           // shares parameter, set to 0 if you're supplying assets directly
            user, // on behalf of this contract
            ""
        );
    }

    
    function _borrow(address user, uint256 borrowAmount) private {
        uint256 ghostStrat = computeGhostStrat(user);
        uint256 maxBorrowable = (ghostStrat * 90) / 100;
        require(borrowAmount <= maxBorrowable, "Exceeds max borrowable amount");


        MarketParams memory marketParams = MarketParams({
            loanToken: address(stratToken),
            collateralToken: address(ghostStratToken),
            oracle: address(0),
            irm: address(0),
            lltv: 90
        });

        morpho.borrow(marketParams, borrowAmount, 0, user, user);
    }
    
   
    function computeGhostStrat(address user) public view returns (uint256) {
        uint256 maxCDT = depositedCDT[user];
        uint256 optionId = depositedOption[user];

        // If no option has been deposited, return 0.
        if (optionId == 0) {
            return 0;
        }

        uint256 optionPrice = stratOption.strikeAmount(optionId);
        uint256 notionalUSDAmount = stratOption.notionalUSDAmount(optionId);

        uint256 effectiveCDT = _max(maxCDT, notionalUSDAmount);
        return (optionPrice * effectiveCDT) / 1e18;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function withdraw(uint256 depositId) external {
        // Ensure the caller is the owner of the deposit.
        require(depositOwners[depositId] == msg.sender, "Not deposit owner");

        // Prepare the market parameters for the collateral (ghostStratToken).
        MarketParams memory marketParams = MarketParams({
            loanToken: address(stratToken),
            collateralToken: address(ghostStratToken),
            oracle: address(0),
            irm: address(0),
            lltv: 90
        });

        // Compute the collateral value based on the user's deposit.
        uint256 ghostStrat = computeGhostStrat(msg.sender);

        // Withdraw the collateral from the Morpho pool.
        // Assuming the supply position was credited to the user,
        // we withdraw on their behalf so that the tokens go to this contract.
        (uint256 assetsWithdrawn, ) = morpho.withdraw(
            marketParams,
            ghostStrat,    // amount of collateral (assets) to withdraw
            0,             // shares parameter (set to 0 for asset-based withdrawal)
            msg.sender,    // on behalf of the user (the collateral position owner)
            address(this)  // tokens are sent to this contract
        );

        // Optionally, check that assetsWithdrawn is as expected.
        require(assetsWithdrawn >= ghostStrat, "Withdrawal error");

        // Burn the ghostStrat tokens now held by this contract.
        ghostStratToken.burn(ghostStrat);

        // Retrieve and clear the deposited CDT amount.
        uint256 cdtAmount = depositedCDT[msg.sender];
        delete depositedCDT[msg.sender];

        // Retrieve and clear the deposited option NFT
        uint256 optionId = depositedOption[msg.sender];
        delete depositedOption[msg.sender];

        // Transfer the CDT and deposited Option NFT tokens back to the user.
        stratOption.transferFrom(address(this), msg.sender, optionId);
        CDT.transfer(msg.sender, cdtAmount);

        // Finally, burn the deposit receipt NFT.
        depositReceipt.burn(depositId);
    }

    function liquidatePosition(
        address borrower,
        uint256 seizedAssets,  // amount of collateral (ghost strat) to seize
        uint256 repaidShares,   // amount of borrow shares to repay (set one to 0 as required)
        bytes memory data
    ) external {
        // Prepare market parameters (should match the ones used for supply/borrow)
        MarketParams memory marketParams = MarketParams({
            loanToken: address(stratToken),
            collateralToken: address(ghostStratToken),
            oracle: address(0),
            irm: address(0),
            lltv: 90
        });
        
        // Liquidate the borrower's position via Morpho.
        // The Morpho contract will seize collateral and reduce the borrower's debt.
        (uint256 assetsSeized, uint256 assetsRepaid) = morpho.liquidate(
            marketParams,
            borrower,
            seizedAssets,   // amount of collateral (assets) to seize (or option to repay)
            repaidShares,   // amount of borrow shares to repay (or 0)
            ""
        );
        
        // Retrieve the borrower's deposited CDT and option.
        uint256 cdtAmount = depositedCDT[borrower];
        uint256 optionId = depositedOption[borrower];
        
        // Clear the borrower's deposit records.
        delete depositedCDT[borrower];
        delete depositedOption[borrower];
        
        // Burn the CDT tokens held by the contract that belonged to the borrower.
        // This removes the CDT from circulation as part of the liquidation penalty.
        CDT.burn(cdtAmount);
        
        // Burn the deposited option NFT.
        // If your StratOption contract doesn't have a burn function,
        // consider transferring it to a burn address instead.
        stratOption.burn(optionId);
        
        // (Optional) If deposit receipt NFTs exist for this borrower, burn them as well.
    }



}
