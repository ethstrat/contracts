// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

interface IWETH {
    function deposit() external payable;
}

interface ILegacyVaultTypes {
    function stEthPerToken() external view returns (uint256);
    function getExchangeRate() external view returns (uint256);
    function exchangeRate() external view returns (uint256);
}


interface IWeETH {
    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256);
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

    enum TokenType {
        UNSUPPORTED,
        ERC20,
        ERC4626,
        WSTETH,
        RETH,
        AWETH,
        WEETH,
        CBETH
    }

    /// @dev Structure to store token configuration
    struct TokenConfig {
        TokenType tokenType; // Type of the token (ERC4626, STETH, WETH, WSTETH)
        bool isMintable; // Whether this token can be used to mint esETH
        bool isRedeemable; // Whether this token can be redeemed for esETH
        uint256 totalMinted;
    }

    /// @dev Mapping from token address to its configuration
    mapping(address token => TokenConfig) public tokenConfigs;

    address public immutable WETH;
    address public yieldReceiver;
    address public treasuryManager;

    /// @dev Events
    event Minted(
        address indexed caller,
        address indexed receiver,
        address indexed token,
        uint256 tokenAmount,
        uint256 esETHAmount
    );
    event Redeemed(
        address indexed caller,
        address indexed receiver,
        address indexed token,
        uint256 tokenAmount,
        uint256 esETHAmount
    );
    event LSTConverted(
        address indexed fromToken, address indexed toToken, uint256 fromAmount, uint256 toAmount, uint256 loss
    );
    event YieldHarvested(uint256 esETHAmount);
    event ExcessBurned(uint256 esETHAmount);
    event YieldReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event TreasuryManagerUpdated(address indexed oldManager, address indexed newManager);

    event TokenConfigUpdated(address indexed token, TokenType tokenType, bool isMintable, bool isRedeemable);

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
    constructor(address _owner, address _weth) ERC20("ETH Strategy ETH", "esETH") Ownable(_owner) {
        if (_weth == address(0)) revert ZeroAddress();
        WETH = _weth;
        yieldReceiver = _owner;
        treasuryManager = _owner;
    }

    /**
     * @notice Mint esETH by depositing a whitelisted LST
     * @param token The LST token to deposit
     * @param tokenAmount The amount of LST tokens to deposit
     * @param receiver The address to receive minted esETH
     * @return esETHAmount The amount of esETH minted
     */
    function mint(address token, uint256 tokenAmount, address receiver)
        external
        nonReentrant
        returns (uint256 esETHAmount)
    {
        // Transfer tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Validate and mint
        esETHAmount = _mintInternal(token, tokenAmount, receiver);
    }

    /**
     * @notice Wrap raw ETH into WETH, then mint esETH using the wrapped WETH as backing
     * @dev Always wraps into the configured WETH address and treats it as the mint token.
     * @param receiver The address to receive minted esETH
     * @return esETHAmount The amount of esETH minted
     */
    function wrapAndMint(address receiver) external payable nonReentrant returns (uint256 esETHAmount) {
        // Wrap into WETH (WETH is minted to this contract)
        IWETH(WETH).deposit{value: msg.value}();

        // Validate and mint
        esETHAmount = _mintInternal(WETH, msg.value, receiver);
    }

    /**
     * @dev Internal helper to mint esETH after tokens are already in the contract
     * @param token The token address used for backing
     * @param tokenAmount The amount of tokens backing this mint
     * @param receiver The address to receive minted esETH
     * @return esETHAmount The amount of esETH minted
     */
    function _mintInternal(address token, uint256 tokenAmount, address receiver)
        internal
        returns (uint256 esETHAmount)
    {
        // Validate inputs
        if (tokenAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // Validate token configuration
        TokenConfig storage config = tokenConfigs[token];
        if (config.tokenType == TokenType.UNSUPPORTED) revert UnsupportedToken(token);
        if (msg.sender != treasuryManager && !config.isMintable) revert TokenNotWhitelistedForMint(token);

        // Calculate ETH value of deposited tokens (rounds down naturally)
        esETHAmount = _convertTokenToETH(token, tokenAmount, config.tokenType);
        config.totalMinted += esETHAmount;

        _mint(receiver, esETHAmount);
        emit Minted(msg.sender, receiver, token, tokenAmount, esETHAmount);
    }

    /**
     * @notice Redeem esETH for a whitelisted LST
     * @param token The LST token to receive
     * @param tokenAmount The amount of the given LST token redeemed for esETH
     * @param receiver The address to receive redeemed tokens
     * @return esETHAmount The amount of esETH burned
     */
    function redeem(address token, uint256 tokenAmount, address receiver)
        external
        nonReentrant
        returns (uint256 esETHAmount)
    {
        if (tokenAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        TokenConfig storage config = tokenConfigs[token];
        if (config.tokenType == TokenType.UNSUPPORTED) revert UnsupportedToken(token);
        if (msg.sender != treasuryManager && !config.isRedeemable) revert TokenNotWhitelistedForRedeem(token);

        // Calculate the ETH value of the LST to be redeemed
        // Always round up by adding 1 wei to prevent rounding exploits
        esETHAmount = _convertTokenToETH(token, tokenAmount, config.tokenType) + 1;

        // Check contract has enough balance
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        if (contractBalance < tokenAmount) revert InsufficientBalance(token);

        // Burn esETH and update totalMinted
        // NOTE: esETHAmount includes +1 wei, but totalMinted only tracks the base value. 
        //       We subtract 1 wei from esETHAmount so everything reconciles. If these accumulate
        //       over time, it will be harvested out
        config.totalMinted -= esETHAmount - 1;
        _burn(msg.sender, esETHAmount);
        IERC20(token).safeTransfer(receiver, tokenAmount);

        emit Redeemed(msg.sender, receiver, token, tokenAmount, esETHAmount);
    }

    /**
     * @notice Owner-only: Update token configuration
     * @param token The token address
     * @param tokenType The type of the token (ERC4626, STETH, WETH, WSTETH)
     * @param isMintable Whether this token can be used to mint esETH
     * @param isRedeemable Whether this token can be redeemed for esETH
     */
    function setTokenConfig(address token, TokenType tokenType, bool isMintable, bool isRedeemable)
        external
        onlyOwner
    {
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
        } else if (tokenType == TokenType.AWETH) {
            // aWETH (Aave V3) is a rebasing token: balanceOf() already returns the current
            // ETH-denominated value (1 aWETH == 1 WETH at any point in time). The Aave
            // liquidity index is baked into the rebased balance, so no further scaling is
            // needed. Applying totalSupply/scaledTotalSupply here would double-count that
            // factor and overstate the value by the accrued-interest ratio (~1.04x).
            return amount;
        } else if (tokenType == TokenType.WEETH) {
            // weETH (ether.fi): convert wrapped weETH amount into its eETH/ETH-equivalent amount.
            return IWeETH(token).getEETHByWeETH(amount);
        } else if (tokenType == TokenType.CBETH) {
            // cbETH: exchangeRate() returns the ETH value of 1 cbETH, scaled by 1e18.
            return amount * ILegacyVaultTypes(token).exchangeRate() / 1e18;
        }

        revert UnsupportedToken(token);
    }

    /**
     * @dev Harvest yield by minting esETH when backing exceeds total minted
     */
    function harvestYield(address[] memory tokens) external nonReentrant {
        uint256 yield = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            TokenConfig memory config = tokenConfigs[t];

            // Only count tokens that are supported
            if (config.tokenType != TokenType.UNSUPPORTED) {
                uint256 balance = IERC20(t).balanceOf(address(this));
                if (balance > 0) {
                    uint256 esETHValueForToken = _convertTokenToETH(t, balance, config.tokenType);
                    if (esETHValueForToken > config.totalMinted) {
                        yield = yield + (esETHValueForToken - config.totalMinted);
                        tokenConfigs[t].totalMinted = esETHValueForToken;
                    }
                }
            }
        }

        if (yield > 0) {
            _mint(yieldReceiver, yield);
            emit YieldHarvested(yield);
        }
    }

    /**
     * @dev Burn excess esETH if total minted exceeds backing.
     *      This function checks each token and calculates if more esETH is minted than backing,
     *      and burns the excess amount from the caller's balance.
     */
    function burnExcess(address[] memory tokens) external nonReentrant {
        uint256 excess = 0;

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
                    excess = excess + (config.totalMinted - esETHValueForToken);
                    tokenConfigs[t].totalMinted = esETHValueForToken;
                }
            }
        }

        if (excess > 0) {
            _burn(msg.sender, excess);
            emit ExcessBurned(excess);
        }
    }

    /**
     * @notice Set the yield receiver address
     * @dev Only the owner can set the yield receiver
     * @param _receiver The new yield receiver address
     */
    function setYieldReceiver(address _receiver) external onlyOwner {
        if (_receiver == address(0)) revert ZeroAddress();
        address old = yieldReceiver;
        yieldReceiver = _receiver;
        emit YieldReceiverUpdated(old, _receiver);
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
