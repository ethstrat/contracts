// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20, IERC20MintableBurnable} from "../interfaces/IERC20.sol";

import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {IMorpho, MarketParams, Id, Position, Market} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/src/libraries/SharesMathLib.sol";
import {IMorphoFlashLoanCallback} from "morpho-blue/src/interfaces/IMorphoCallbacks.sol";

/// @title A proxy around the strat/eth borrow market
/// @dev It's required to control liquidation incentives and liquidation via burn
contract MorphoStratProxy is ERC20Permit, Ownable2Step, IMorphoFlashLoanCallback {
    IMorpho public morphoMoneyMarket;
    MarketParams public marketParams;
    Id public marketId;
    IERC20MintableBurnable public immutable stratToken;
    address public immutable treasury;

    error ZeroAssets();
    error ZeroAddress();
    error InvalidLltv(uint256 lltv);

    struct LiquidateData {
        address liquidator;
        address borrower;
        uint256 borrowerShares;
    }

    constructor(
        string memory name,
        string memory symbol,
        address _morphoMoneyMarket,
        address _stratToken,
        address _owner,
        address _treasury
    ) ERC20(name, symbol) ERC20Permit(name) Ownable(_owner) {
        morphoMoneyMarket = IMorpho(_morphoMoneyMarket);
        stratToken = IERC20MintableBurnable(_stratToken);
        treasury = _treasury;
    }

    /// @dev intialize the marketParams. Should only be called once by the owner
    function initializeMarketParams(address loanToken, address oracle, address irm, uint256 lltv) external onlyOwner {
        if (loanToken == address(0)) revert ZeroAddress();
        if (irm == address(0)) revert ZeroAddress();
        if (!morphoMoneyMarket.isLltvEnabled(lltv)) revert InvalidLltv(lltv);

        marketParams.collateralToken = address(this);
        marketParams.loanToken = loanToken;
        marketParams.oracle = oracle;
        marketParams.irm = irm;
        marketParams.lltv = lltv;

        // Initialise marketId at construction as well
        marketId = MarketParamsLib.id(marketParams);
    }

    /// @notice Supplies `assets` of collateral on behalf of `onBehalf`, optionally calling back the caller's
    /// `onMorphoSupplyCollateral` function with the given `data`.
    /// @dev caller must approve `stratToken` to this contract. Wrapper then mints the wrapper token
    /// @dev and deposits into the morpho market
    /// @param assets The amount of collateral to supply.
    /// @param onBehalf The address that will own the increased collateral position.
    /// @param data Arbitrary data to pass to the `onMorphoSupplyCollateral` callback. Pass empty data if not needed.
    function supplyCollateral(uint256 assets, address onBehalf, bytes memory data) external {
        if (onBehalf == address(0)) revert ZeroAddress();

        stratToken.transferFrom(msg.sender, address(this), assets);
        approve(address(morphoMoneyMarket), assets);
        _mint(address(this), assets);

        morphoMoneyMarket.supplyCollateral(marketParams, assets, onBehalf, data);
    }

    /// @notice Withdraws `assets` of collateral and sends the assets to `receiver`.
    /// @notice burns wrapper, and sends `stratToken` to the receiever
    /// @notice `address(this)` must be authorized to manage `msg.sender`'s positions.
    /// @dev Withdrawing an amount corresponding to more collateral than supplied will revert for underflow.
    /// @dev `msg.sender` must be authorized to manage `onBehalf`'s positions.
    /// @dev Withdrawing an amount corresponding to more collateral than supplied will revert for underflow.
    /// @param assets The amount of collateral to withdraw.
    /// @param receiver The address that will receive the collateral assets.
    function withdrawCollateral(uint256 assets, address receiver) external {
        morphoMoneyMarket.withdrawCollateral(marketParams, assets, msg.sender, address(this));
        _burn(address(this), assets);
        stratToken.transfer(receiver, assets);
    }

    /// @notice Liquidates entire debt for a given borrower. Caller gets a small incentive
    /// @param borrower The owner of the position.
    function liquidate(address borrower) external {
        Position memory position = morphoMoneyMarket.position(marketId, borrower);
        Market memory market = morphoMoneyMarket.market(marketId);

        uint256 borrowerAssets =
            SharesMathLib.toAssetsUp(position.borrowShares, market.totalBorrowAssets, market.totalBorrowShares);

        // perform rest of the liquidate flash loan, in the flashLoan callback
        // (liquidate, then pay back flash by withdrawing loanToken from the market, then pay liquidator)
        morphoMoneyMarket.flashLoan(
            marketParams.loanToken,
            borrowerAssets,
            abi.encode(LiquidateData(msg.sender, borrower, position.borrowShares))
        );
    }

    /// @inheritdoc IMorphoFlashLoanCallback
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        LiquidateData memory ldata = abi.decode(data, (LiquidateData));

        // liquidate the borrower
        IERC20(marketParams.loanToken).approve(address(morphoMoneyMarket), assets);
        (uint256 seizedAssets,) =
            morphoMoneyMarket.liquidate(marketParams, ldata.borrower, 0, ldata.borrowerShares, new bytes(0));

        // pay back the flash loan
        IERC20(marketParams.loanToken).approve(address(morphoMoneyMarket), assets);
        morphoMoneyMarket.withdraw(marketParams, assets, 0, address(this), address(this));

        // pay liquidation incentive, and burn siezed assets
        uint256 incentive = seizedAssets / 100;

        _burn(address(this), seizedAssets);
        stratToken.transfer(ldata.liquidator, incentive);
        stratToken.burn(seizedAssets - incentive);
    }

    /// @dev owner only function to pull assets from the morpho market
    /// @dev and send back to treasury
    function withdraw(uint256 amount, uint256 shares) external onlyOwner {
        if (amount == 0) revert ZeroAssets();

        morphoMoneyMarket.withdraw(marketParams, amount, shares, address(this), treasury);
    }

    /// @dev owner only function that pulls assets from treasury and supply
    /// @dev to the morpho market
    function supply(uint256 amount, uint256 shares) external onlyOwner {
        if (amount == 0) revert ZeroAssets();

        IERC20(marketParams.loanToken).transferFrom(address(treasury), address(this), amount);
        morphoMoneyMarket.supply(marketParams, amount, shares, address(this), new bytes(0));
    }
}
