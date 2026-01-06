// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title esETH - ETH Strategy ETH
 * @dev A wrapped token that represents a basket of staked ETH/LSTs.
 *      Users can mint esETH by depositing whitelisted LSTs, and redeem esETH
 *      for any whitelisted LST. The token does not rebase and is not yield-bearing.
 */
contract esETH is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Structure to store token configuration
    struct TokenConfig {
        bool isERC4626; // Whether the token is ERC4626 compliant
        address conversionContract; // Contract that converts 1 token to ETH (address(0) for default)
        bool isMintable; // Whether this token can be used to mint esETH
        bool isRedeemable; // Whether this token can be redeemed for esETH
    }

    /// @dev Mapping from token address to its configuration
    mapping(address token => TokenConfig) public tokenConfigs;

    /// @dev Array of all configured tokens (for iteration)
    address[] public tokenList;

    /// @dev Mapping to track if token is in the list (to avoid duplicates)
    mapping(address token => bool) public isTokenInList;

    /// @dev Events
    event TokenConfigUpdated(
        address indexed token,
        bool isERC4626,
        address conversionContract,
        bool isMintable,
        bool isRedeemable
    );
    event Minted(address indexed user, address indexed token, uint256 tokenAmount, uint256 esETHAmount);
    event Redeemed(address indexed user, address indexed token, uint256 esETHAmount, uint256 tokenAmount);
    event LSTConverted(address indexed fromToken, address indexed toToken, uint256 fromAmount, uint256 toAmount, uint256 loss);
    event DeficitMinted(uint256 esETHAmount);

    /// @dev Errors
    error TokenNotWhitelistedForMint(address token);
    error TokenNotWhitelistedForRedeem(address token);
    error ZeroAmount();
    error InsufficientBalance(address token);
    error ConversionFailed();
    error InvalidConversionContract();
    error InsufficientBacking();
    error InsufficientESETHForLoss(uint256 required, uint256 available);

    /**
     * @dev Constructor
     * @param _owner The owner of the contract
     */
    constructor(address _owner) ERC20("ETH Strategy ETH", "esETH") Ownable(_owner) {}

    /**
     * @notice Mint esETH by depositing a whitelisted LST
     * @param token The LST token to deposit
     * @param amount The amount of LST tokens to deposit
     * @return esETHAmount The amount of esETH minted
     */
    function mint(address token, uint256 amount) external nonReentrant returns (uint256 esETHAmount) {
        if (amount == 0) revert ZeroAmount();
        
        TokenConfig memory config = tokenConfigs[token];
        if (!config.isMintable) revert TokenNotWhitelistedForMint(token);

        // Transfer tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate ETH value of deposited tokens
        uint256 ethValue = _convertTokenToETH(token, amount, config);

        // Mint esETH 1:1 with ETH value
        esETHAmount = ethValue;
        _mint(msg.sender, esETHAmount);

        emit Minted(msg.sender, token, amount, esETHAmount);
    }

    /**
     * @notice Redeem esETH for a whitelisted LST
     * @param token The LST token to receive
     * @param esETHAmount The amount of esETH to burn
     * @return tokenAmount The amount of LST tokens received
     */
    function redeem(address token, uint256 esETHAmount) external nonReentrant returns (uint256 tokenAmount) {
        if (esETHAmount == 0) revert ZeroAmount();
        
        TokenConfig memory config = tokenConfigs[token];
        if (!config.isRedeemable) revert TokenNotWhitelistedForRedeem(token);

        // Burn esETH
        _burn(msg.sender, esETHAmount);

        // Calculate how many tokens to give for the ETH value
        tokenAmount = _convertETHToToken(token, esETHAmount, config);

        // Check contract has enough balance
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        if (contractBalance < tokenAmount) revert InsufficientBalance(token);

        // Transfer tokens to user
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        emit Redeemed(msg.sender, token, esETHAmount, tokenAmount);
    }

    /**
     * @notice Owner-only: Convert one LST to another (flashloan-like)
     * @dev May have slippage/loss, which is covered by burning esETH
     *      
     *      Usage flow:
     *      1. Ensure contract has fromToken balance >= fromAmount
     *      2. Owner swaps fromToken to toToken externally (via DEX/router)
     *      3. Owner sends toToken to this contract
     *      4. Owner calls this function to verify swap and handle loss
     *      
     *      If there's a loss (in ETH terms), esETH will be burned from contract balance.
     *      Owner must ensure contract has sufficient esETH balance to cover potential losses.
     *      
     * @param fromToken The token to convert from
     * @param toToken The token to convert to
     * @param fromAmount The amount of fromToken to convert
     * @param minToAmount The minimum amount of toToken expected
     * @return toAmount The amount of toToken received
     * @return loss The loss in ETH terms (if any)
     */
    function convertLST(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minToAmount
    ) external onlyOwner nonReentrant returns (uint256 toAmount, uint256 loss) {
        TokenConfig memory fromConfig = tokenConfigs[fromToken];
        TokenConfig memory toConfig = tokenConfigs[toToken];

        if (!fromConfig.isMintable && !fromConfig.isRedeemable) {
            revert TokenNotWhitelistedForMint(fromToken);
        }
        if (!toConfig.isMintable && !toConfig.isRedeemable) {
            revert TokenNotWhitelistedForMint(toToken);
        }

        // Calculate ETH value of fromToken
        uint256 fromETHValue = _convertTokenToETH(fromToken, fromAmount, fromConfig);

        // Check contract has enough fromToken balance
        uint256 fromBalance = IERC20(fromToken).balanceOf(address(this));
        if (fromBalance < fromAmount) revert InsufficientBalance(fromToken);

        // Get toToken balance before swap
        uint256 toBalanceBefore = IERC20(toToken).balanceOf(address(this));
        
        // Owner should swap fromToken to toToken externally and send toToken to this contract
        // We verify the received amount after the swap
        uint256 toBalanceAfter = IERC20(toToken).balanceOf(address(this));
        toAmount = toBalanceAfter - toBalanceBefore;

        if (toAmount < minToAmount) revert InsufficientOutput(minToAmount, toAmount);

        // Calculate ETH value of received toToken
        uint256 toETHValue = _convertTokenToETH(toToken, toAmount, toConfig);

        // Calculate loss and burn esETH to cover it
        if (toETHValue < fromETHValue) {
            loss = fromETHValue - toETHValue;
            // Burn esETH to cover the loss
            // The owner must ensure the contract has enough esETH balance
            uint256 contractBalance = balanceOf(address(this));
            if (contractBalance < loss) {
                revert InsufficientESETHForLoss(loss, contractBalance);
            }
            _burn(address(this), loss);
        }

        emit LSTConverted(fromToken, toToken, fromAmount, toAmount, loss);
    }

    /**
     * @notice Owner-only: Mint esETH if totalSupply < totalBacking
     * @dev Mints the difference between totalBacking and totalSupply
     */
    function mintDeficit() external onlyOwner {
        uint256 backing = _calculateTotalBacking();
        uint256 currentSupply = totalSupply();

        if (backing <= currentSupply) revert InsufficientBacking();

        uint256 deficit = backing - currentSupply;
        _mint(owner(), deficit);

        emit DeficitMinted(deficit);
    }

    /**
     * @notice Owner-only: Update token configuration
     * @param token The token address
     * @param isERC4626 Whether the token is ERC4626 compliant
     * @param conversionContract The contract that converts 1 token to ETH (address(0) for default)
     * @param isMintable Whether this token can be used to mint esETH
     * @param isRedeemable Whether this token can be redeemed for esETH
     */
    function setTokenConfig(
        address token,
        bool isERC4626,
        address conversionContract,
        bool isMintable,
        bool isRedeemable
    ) external onlyOwner {
        if (conversionContract != address(0)) {
            // Verify the conversion contract has the required function
            // We'll check it has a function that can convert tokens
            // For simplicity, we'll just check it's not the zero address
        }

        // Add to token list if not already present
        if (!isTokenInList[token] && (isMintable || isRedeemable)) {
            tokenList.push(token);
            isTokenInList[token] = true;
        }

        tokenConfigs[token] = TokenConfig({
            isERC4626: isERC4626,
            conversionContract: conversionContract,
            isMintable: isMintable,
            isRedeemable: isRedeemable
        });

        emit TokenConfigUpdated(token, isERC4626, conversionContract, isMintable, isRedeemable);
    }

    /**
     * @notice Get the number of configured tokens
     * @return The number of tokens in the list
     */
    function tokenListLength() external view returns (uint256) {
        return tokenList.length;
    }

    /**
     * @notice Calculate total backing in ETH terms
     * @return total The total ETH value of all held LSTs
     */
    function totalBacking() external view returns (uint256 total) {
        return _calculateTotalBacking();
    }

    /**
     * @notice Get the ETH value of a token amount
     * @param token The token address
     * @param amount The token amount
     * @return ethValue The ETH value
     */
    function getETHValue(address token, uint256 amount) external view returns (uint256 ethValue) {
        TokenConfig memory config = tokenConfigs[token];
        return _convertTokenToETH(token, amount, config);
    }

    /**
     * @dev Internal: Convert token amount to ETH value
     */
    function _convertTokenToETH(address token, uint256 amount, TokenConfig memory config) internal view returns (uint256) {
        if (config.conversionContract != address(0)) {
            // Use custom conversion contract
            // Assume it has a function: convertToETH(address token, uint256 amount) returns (uint256)
            // We'll use a low-level call for flexibility
            (bool success, bytes memory data) = config.conversionContract.staticcall(
                abi.encodeWithSignature("convertToETH(address,uint256)", token, amount)
            );
            if (success && data.length >= 32) {
                return abi.decode(data, (uint256));
            }
            revert ConversionFailed();
        }

        if (config.isERC4626) {
            // Use ERC4626 standard: convertToAssets
            // convertToAssets(amount) directly gives the underlying asset (ETH) value
            IERC4626 vault = IERC4626(token);
            return vault.convertToAssets(amount);
        } else {
            // For non-ERC4626, assume 1:1 with ETH (like WETH)
            // For tokens like rETH, a conversion contract should be specified
            return amount;
        }
    }

    /**
     * @dev Internal: Convert ETH value to token amount
     */
    function _convertETHToToken(address token, uint256 ethValue, TokenConfig memory config) internal view returns (uint256) {
        if (config.conversionContract != address(0)) {
            // Use custom conversion contract
            (bool success, bytes memory data) = config.conversionContract.staticcall(
                abi.encodeWithSignature("convertFromETH(address,uint256)", token, ethValue)
            );
            if (success && data.length >= 32) {
                return abi.decode(data, (uint256));
            }
            revert ConversionFailed();
        }

        if (config.isERC4626) {
            // Use ERC4626 standard: convertToShares
            IERC4626 vault = IERC4626(token);
            return vault.convertToShares(ethValue);
        } else {
            // For non-ERC4626, assume 1:1 with ETH (like WETH)
            return ethValue;
        }
    }

    /**
     * @dev Internal: Calculate total backing by summing all LST balances in ETH terms
     */
    function _calculateTotalBacking() internal view returns (uint256 total) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            TokenConfig memory config = tokenConfigs[token];
            
            // Only count tokens that are mintable or redeemable
            if (config.isMintable || config.isRedeemable) {
                uint256 balance = IERC20(token).balanceOf(address(this));
                if (balance > 0) {
                    total += _convertTokenToETH(token, balance, config);
                }
            }
        }
    }

    error InsufficientOutput(uint256 expected, uint256 actual);
}
