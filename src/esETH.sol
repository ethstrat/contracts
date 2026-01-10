// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

interface ILegacyVaultTypes {
    function stEthPerToken() external view returns (uint256);
    function getExchangeRate() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function ratio() external view returns (uint256);
    function exchangeRate() external view returns (uint256);
}

interface IAaveV2AToken {
    function getScaledUserBalance(address user) external view returns (uint256);
    function getScaledTotalSupply() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/**
 * @title esETH - ETH Strategy's ETH
 * @dev A wrapped token that represents a basket of staked ETH/LSTs (Eth Strategy's Treasury)
 *      Users can mint esETH by depositing whitelisted LSTs, and redeem esETH
 *      for any whitelisted LST. The token does not rebase and is not yield-bearing.
 * .    Yield is periodically 'harvested' by minting more esETH if the total backing 
 * .    exceeds total supply
 */
contract esETH is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum TokenType { UNSUPPORTED, ERC20, ERC4626, WSTETH, RETH, CETH, AETHV2, ANKRETH, CBETH }

    /// @dev Structure to store token configuration
    struct TokenConfig {
        TokenType tokenType; // Type of the token (ERC4626, STETH, WETH, WSTETH)
        bool isMintable; // Whether this token can be used to mint esETH
        bool isRedeemable; // Whether this token can be redeemed for esETH
        uint256 totalMinted;
    }

    /// @dev Mapping from token address to its configuration
    mapping(address token => TokenConfig) public tokenConfigs;

    address public harvestReceiver;
    address public treasuryManager;

    /// @dev Events
    event Minted(address indexed user, address indexed token, uint256 tokenAmount, uint256 esETHAmount);
    event Redeemed(address indexed user, address indexed token, uint256 tokenAmount, uint256 esETHAmount);
    event LSTConverted(address indexed fromToken, address indexed toToken, uint256 fromAmount, uint256 toAmount, uint256 loss);
    event DeficitMinted(uint256 esETHAmount);
    event SurplusBurned(uint256 esETHAmount);
    event HarvestReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event TreasuryManagerUpdated(address indexed oldManager, address indexed newManager);

    event TokenConfigUpdated(
        address indexed token,
        TokenType tokenType,
        bool isMintable,
        bool isRedeemable
    );

    /// @dev Errors
    error TokenNotWhitelistedForMint(address token);
    error TokenNotWhitelistedForRedeem(address token);
    error UnsupportedToken(address token);
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientBalance(address token);

    /**
     * @dev Constructor
     * @param _owner The owner of the contract
     */
    constructor(address _owner) ERC20("ETH Strategy ETH", "esETH") Ownable(_owner) {
        harvestReceiver = _owner;
        treasuryManager = _owner;
    }

    /**
     * @notice Mint esETH by depositing a whitelisted LST
     * @param token The LST token to deposit
     * @param tokenAmount The amount of LST tokens to deposit
     * @return esETHAmount The amount of esETH minted
     */
    function mint(address token, uint256 tokenAmount) external nonReentrant returns (uint256 esETHAmount) {
        if (tokenAmount == 0) revert ZeroAmount();
        
        TokenConfig memory config = tokenConfigs[token];
        if (config.tokenType == TokenType.UNSUPPORTED) revert UnsupportedToken(token);
        if (msg.sender != treasuryManager && !config.isMintable) revert TokenNotWhitelistedForMint(token);

        // Transfer tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Calculate ETH value of deposited tokens
        esETHAmount = _convertTokenToETH(token, tokenAmount, config.tokenType);
        tokenConfigs[token].totalMinted += esETHAmount;

        _mint(msg.sender, esETHAmount);
        emit Minted(msg.sender, token, tokenAmount, esETHAmount);
    }

    /**
     * @notice Redeem esETH for a whitelisted LST
     * @param token The LST token to receive
     * @param tokenAmount The amount of the given LST token redeemed for esETH
     * @return esETHAmount The amount of esETH burned
     */
    function redeem(address token, uint256 tokenAmount) external nonReentrant returns (uint256 esETHAmount) {
        if (tokenAmount == 0) revert ZeroAmount();
        
        TokenConfig storage config = tokenConfigs[token];
        if (config.tokenType == TokenType.UNSUPPORTED) revert UnsupportedToken(token);
        if (msg.sender != treasuryManager && !config.isRedeemable) revert TokenNotWhitelistedForRedeem(token);

        // Calculate the ETH value of the LST to be redeemed (this is the amounbt of esETH to burn)
        esETHAmount = _convertTokenToETH(token, tokenAmount, config.tokenType);

        // Check contract has enough balance
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        if (contractBalance < tokenAmount) revert InsufficientBalance(token);

        // Burn esETH and update totalMinted
        config.totalMinted -= esETHAmount;
        _burn(msg.sender, esETHAmount);
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        emit Redeemed(msg.sender, token, tokenAmount, esETHAmount);
    }

    /**
     * @notice Owner-only: Update token configuration
     * @param token The token address
     * @param tokenType The type of the token (ERC4626, STETH, WETH, WSTETH)
     * @param isMintable Whether this token can be used to mint esETH
     * @param isRedeemable Whether this token can be redeemed for esETH
     */
    function setTokenConfig(
        address token,
        TokenType tokenType,
        bool isMintable,
        bool isRedeemable
    ) external onlyOwner {
        if (token == address(0)) {
            revert ZeroAddress();
        }

        uint256 totalMinted = tokenConfigs[token].totalMinted;
        tokenConfigs[token] = TokenConfig({
            tokenType: tokenType,
            isMintable: isMintable,
            isRedeemable: isRedeemable,
            totalMinted: totalMinted
        });

        emit TokenConfigUpdated(token, tokenType, isMintable, isRedeemable);
    }

    /**
     * @notice Get the ETH value of a token amount
     * @param token The token address
     * @param amount The token amount
     * @return ethValue The ETH value
     */
    function getETHValue(address token, uint256 amount) external view returns (uint256 ethValue) {
        TokenConfig memory config = tokenConfigs[token];
        if (config.tokenType == TokenType.UNSUPPORTED) {
            revert UnsupportedToken(token);
        }

        return _convertTokenToETH(token, amount, config.tokenType);
    }

    /**
     * @dev Internal: Convert token amount to ETH value
     */
    function _convertTokenToETH(address token, uint256 amount, TokenType tokenType) internal view returns (uint256) {
        if (tokenType == TokenType.ERC4626) {
            // Use ERC4626 standard: convertToAssets
            // convertToAssets(amount) directly gives the underlying asset (ETH) value
            IERC4626 vault = IERC4626(token);
            return vault.convertToAssets(amount);
        } else if (tokenType == TokenType.ERC20) {
            return amount;
        } else if (tokenType == TokenType.WSTETH) {
            // wstETH (Wrapped stETH) is not ERC4626, but exposes stEthPerToken()
            // Converting wstETH to its underlying ETH (stETH)
            // Interface: function stEthPerToken() external view returns (uint256);
            return amount * ILegacyVaultTypes(token).stEthPerToken() / 1e18;
        } else if (tokenType == TokenType.RETH) {
            // rETH: rethPerToken() returns the ETH value of 1 rETH, scaled by 1e18.
            return amount * ILegacyVaultTypes(token).getExchangeRate() / 1e18;
        } else if (tokenType == TokenType.CETH) {
            // cETH: exchangeRateStored() returns the exchange rate (cETH to ETH), scaled by 1e18.
            // Formula: ETH = cETH * exchangeRateStored() / 1e18
            return amount * ILegacyVaultTypes(token).exchangeRateStored() / 1e18;
        } else if (tokenType == TokenType.AETHV2) {
            // aETHv2: Aave v2 aTokens are rebasing tokens where balance increases over time.
            // The balance itself represents the underlying ETH value (it's already rebased).
            // However, to calculate the exchange rate, we use: totalSupply / scaledTotalSupply
            // This gives us the current exchange rate multiplier.
            IAaveV2AToken aToken = IAaveV2AToken(token);
            uint256 scaledTotalSupply = aToken.getScaledTotalSupply();
            if (scaledTotalSupply == 0) return amount;
            uint256 totalSupply = aToken.totalSupply();
            // Calculate the exchange rate: totalSupply / scaledTotalSupply
            // This represents how much underlying ETH each aToken is worth
            return amount * totalSupply / scaledTotalSupply;
        } else if (tokenType == TokenType.ANKRETH) {
            // ankrETH: ratio() returns the ETH value of 1 ankrETH, scaled by 1e18.
            return amount * ILegacyVaultTypes(token).ratio() / 1e18;
        } else if (tokenType == TokenType.CBETH) {
            // cbETH: exchangeRate() returns the ETH value of 1 cbETH, scaled by 1e18.
            return amount * ILegacyVaultTypes(token).exchangeRate() / 1e18;
        }

        revert UnsupportedToken(token);
    }

    /**
     * @dev Mint deficit esETH based on backing vs total minted
     */
    function mintDeficit(address[] memory tokens) external nonReentrant {
        uint256 deficit = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            TokenConfig memory config = tokenConfigs[t];
            
            // Only count tokens that are supported
            if (config.tokenType != TokenType.UNSUPPORTED) {
                uint256 balance = IERC20(t).balanceOf(address(this));
                if (balance > 0) {
                    uint256 esETHValueForToken = _convertTokenToETH(t, balance, config.tokenType);
                    if (esETHValueForToken > config.totalMinted) {
                        deficit = deficit + (esETHValueForToken - config.totalMinted);
                        tokenConfigs[t].totalMinted = esETHValueForToken;
                    }
                }
            }
        }

        if (deficit > 0) {
            _mint(harvestReceiver, deficit);
            emit DeficitMinted(deficit);
        }
    }

    /**
     * @dev Burn surplus esETH if total minted exceeds backing.
     *      This function checks each token and calculates if more esETH is minted than backing,
     *      and burns the surplus amount from the contract's own balance.
     */
    function burnSurplus(address[] memory tokens) external nonReentrant {
        uint256 surplus = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            TokenConfig memory config = tokenConfigs[t];
            
            // Only count tokens that are supported
            if (config.tokenType != TokenType.UNSUPPORTED) {
                uint256 balance = IERC20(t).balanceOf(address(this));
                uint256 esETHValueForToken = 0;
                if (balance > 0) {
                    esETHValueForToken = _convertTokenToETH(t, balance, config.tokenType);
                }
                if (config.totalMinted > esETHValueForToken) {
                    surplus = surplus + (config.totalMinted - esETHValueForToken);
                    tokenConfigs[t].totalMinted = esETHValueForToken;
                }
            }
        }

        if (surplus > 0) {
            _burn(msg.sender, surplus);
            emit SurplusBurned(surplus);
        }
    }

    /**
     * @notice Set the harvest receiver address
     * @dev Only the owner can set the harvest receiver
     * @param _receiver The new harvest receiver address
     */
    function setHarvestReceiver(address _receiver) external onlyOwner {
        if (_receiver == address(0)) revert ZeroAddress();
        address old = harvestReceiver;
        harvestReceiver = _receiver;
        emit HarvestReceiverUpdated(old, _receiver);
    }

    /**
     * @notice Set the treasury manager address
     * @dev Only the owner can set the treasury manager
     * @param _manager The new treasury manager address
     */
    function setTreasuryManager(address _manager) external onlyOwner {
        if (_manager == address(0)) revert ZeroAddress();
        address old = treasuryManager;
        treasuryManager = _manager;
        emit TreasuryManagerUpdated(old, _manager);
    }
}
