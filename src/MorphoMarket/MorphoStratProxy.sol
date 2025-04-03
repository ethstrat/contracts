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

/// @title MorphoStratProxy
/// @notice A proxy for the strat/ETH borrow market. It governs deposit, withdrawal and liquidation
///         actions while controlling liquidation incentives and enabling liquidation via token burn.
/// @dev Only the owner can initialize market parameters and perform owner-specific asset transfers.
contract MorphoStratProxy is ERC20Permit, Ownable2Step, IMorphoFlashLoanCallback {
    /// @notice The Morpho money market contract used for managing collateral and loans.
    IMorpho public morphoMoneyMarket;

    /// @notice Parameters defining the market, such as collateral token, loan token, oracle, etc.
    MarketParams public marketParams;

    /// @notice Unique identifier for the market, derived from the market parameters.
    Id public marketId;

    /// @notice The strategy token that is mintable and burnable, representing collateral shares.
    IERC20MintableBurnable public immutable stratToken;

    /// @notice The address of the treasury where excess funds are sent or pulled from.
    address public immutable treasury;

    /// @dev Error thrown when the amount of assets is zero.
    error ZeroAssets();

    /// @dev Error thrown when an address provided is the zero address.
    error ZeroAddress();

    /// @dev Error thrown when an invalid loan-to-liquidation threshold value is provided.
    /// @param lltv The invalid loan-to-liquidation threshold value.
    error InvalidLltv(uint256 lltv);

    /// @dev Error thrown when the caller of the flash loan callback is not authorized.
    /// @param caller The address of the unauthorized caller.
    error UnauthorizedMorphoFlashLoanCaller(address caller);

    /// @dev Struct to hold data required for liquidation during a flash loan callback.
    /// @param liquidator The address of the liquidator performing the liquidation.
    /// @param borrower The address of the borrower whose position is being liquidated.
    /// @param borrowerShares The number of borrow shares held by the borrower.
    struct LiquidateData {
        address liquidator;
        address borrower;
        uint256 borrowerShares;
    }

    /// @dev Constructor for the `MorphoStratProxy` contract.
    /// Initializes the contract and sets up any required state or dependencies.
    /// Additional details about the parameters and initialization logic
    /// should be provided here if applicable.
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

    /// @notice Initializes the market parameters. Should only be called once by the owner.
    /// @dev Reverts if any critical parameter (loanToken or irm) is address zero, or if the provided LLTV is not
    /// enabled.
    /// @param loanToken The token borrowed in the market.
    /// @param oracle The price oracle address.
    /// @param irm The interest rate model address.
    /// @param lltv The loan-to-value ratio (LLTV) to validate.
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

    /// @notice Supplies a specified amount of collateral on behalf of a given address.
    /// @dev Caller must first approve `stratToken` to this contract.
    ///      This function transfers the collateral from the sender, mints proxy tokens,
    ///      and then deposits the collateral into the Morpho market.
    /// @param assets The amount of collateral to supply.
    /// @param onBehalf The address that will own the resulting increased collateral position.
    /// @param data Arbitrary data passed to the `onMorphoSupplyCollateral` callback.
    function supplyCollateral(uint256 assets, address onBehalf, bytes memory data) external {
        if (onBehalf == address(0)) revert ZeroAddress();

        stratToken.transferFrom(msg.sender, address(this), assets);
        approve(address(morphoMoneyMarket), assets);
        _mint(address(this), assets);

        morphoMoneyMarket.supplyCollateral(marketParams, assets, onBehalf, data);
    }

    /// @notice Withdraws a specified amount of collateral and sends it to the receiver.
    /// @dev This function withdraws collateral from the Morpho market, burns the corresponding proxy tokens,
    ///      and then transfers the underlying `stratToken` to the specified receiver.
    ///      Caller must be authorized to manage the collateral position (i.e. `address(this)` is authorized).
    /// @param assets The amount of collateral to withdraw.
    /// @param receiver The address receiving the withdrawn collateral.
    function withdrawCollateral(uint256 assets, address receiver) external {
        morphoMoneyMarket.withdrawCollateral(marketParams, assets, msg.sender, address(this));
        _burn(address(this), assets);
        stratToken.transfer(receiver, assets);
    }

    /// @notice Liquidates an entire borrower's debt position if unhealthy.
    /// @dev This function computes the borrower's debt in assets from their borrow shares,
    ///      and then initiates a flash loan to perform the liquidation.
    ///      The flash loan callback (`onMorphoFlashLoan`) is used to complete the process.
    /// @param borrower The address owning the position to be liquidated.
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
        if (msg.sender != address(morphoMoneyMarket)) revert UnauthorizedMorphoFlashLoanCaller(msg.sender);

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

    /// @notice Owner-only function to withdraw assets from the Morpho market back to the treasury.
    /// @dev Reverts if the requested withdrawal amount is zero.
    /// @param amount The amount of assets to withdraw.
    /// @param shares The corresponding number of shares to burn.
    function withdraw(uint256 amount, uint256 shares) external onlyOwner {
        if (amount == 0) revert ZeroAssets();

        morphoMoneyMarket.withdraw(marketParams, amount, shares, address(this), treasury);
    }

    /// @notice Owner-only function to supply assets from the treasury to the Morpho market.
    /// @dev Reverts if the supplied amount is zero.
    /// @param amount The amount of assets to supply.
    /// @param shares The corresponding shares for the supply.
    function supply(uint256 amount, uint256 shares) external onlyOwner {
        if (amount == 0) revert ZeroAssets();

        IERC20(marketParams.loanToken).transferFrom(address(treasury), address(this), amount);
        morphoMoneyMarket.supply(marketParams, amount, shares, address(this), new bytes(0));
    }
}
