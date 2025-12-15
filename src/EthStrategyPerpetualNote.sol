// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ETH Strategy Perpetual Note
 * @dev Eth Strategy perpetual note. A defi version of MSTR's preferred stock
 *      The vault is designed to allow flexibility w.r.t the underlying strategy
 *      (owners can set the manager)
 */
contract EthStrategyPerpetualNote is ERC4626, Ownable2Step, ReentrancyGuard {
    using Math for uint256;

    address public manager;

    uint256 private _totalAssets;

    /// @dev Maximum total assets that can be deposited (uint256 max = no cap)
    uint256 public depositCap;

    /// @dev Withdrawals are disabled by default. Exit is via LP
    bool public withdrawalsDisabled = true;

    /// @dev Events
    event ManagerUpdated(address indexed newManager);
    event WithdrawalsDisabledUpdated(bool isWithdrawalsDisabled);
    event DepositCapUpdated(uint256 newCap);
    event AssetsPerShareIncreased(address indexed caller, uint256 newAssetsPerShare, uint256 delta);

    /// @dev Errors
    error InvalidManager();

    /**
     * @dev Constructor for the vault
     * @param _asset The underlying ERC20 token for the vault
     * @param _owner The owner of the vault
     */
    constructor(IERC20 _asset, address _owner)
        ERC4626(_asset)
        ERC20("ETH Strategy Perpetual Note", "ESPN")
        Ownable(_owner)
    {}

    /**
     * @dev See {IERC4626-totalAssets}.
     */
    function totalAssets() public view virtual override returns (uint256) {
        return _totalAssets;
    }

    function increaseAssetsPerShare(uint256 assets) external {
        SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), assets);
        SafeERC20.safeTransfer(IERC20(asset()), manager, assets);
        _totalAssets += assets;

        emit AssetsPerShareIncreased(msg.sender, _totalAssets, assets);
    }

    /**
     * @dev See {IERC4626-maxDeposit}.
     */
    function maxDeposit(address) public view virtual override returns (uint256) {
        return depositCap > _totalAssets ? depositCap - _totalAssets : 0;
    }

    /**
     * @dev See {IERC4626-maxMint}.
     */
    function maxMint(address) public view virtual override returns (uint256) {
        return previewDeposit(maxDeposit(address(0)));
    }

    /**
     * @dev See {IERC4626-maxWithdraw}.
     */
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        if (withdrawalsDisabled) {
            return 0;
        }

        // The withdrawable amount is the minimum of:
        // - the owner's share of assets (converted from their shares)
        // - the actual asset balance held by the contract
        uint256 ownerAssets = super.maxWithdraw(owner);
        uint256 contractBalance = IERC20(asset()).balanceOf(address(this));
        return ownerAssets < contractBalance ? ownerAssets : contractBalance;
    }

    /**
     * @dev See {IERC4626-maxRedeem}.
     */
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        if (withdrawalsDisabled) {
            return 0;
        }

        // The maximum shares redeemable is the minimum of:
        // - the owner's share balance
        // - the number of shares that can be redeemed given the contract's asset balance
        uint256 contractBalance = IERC20(asset()).balanceOf(address(this));
        uint256 maxSharesForContractBalance = convertToShares(contractBalance);
        uint256 ownerShares = balanceOf(owner);
        return ownerShares < maxSharesForContractBalance ? ownerShares : maxSharesForContractBalance;
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * intentended to be used by the STRAT protocol if it needs to burn any ESPN it holds to
     * boost yield for external holders.
     *
     * @param value The amount of tokens to burn
     */
    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }

    /**
     * @dev Override of _deposit to
     *   1. track totalAssets explicitly
     *   2. transfer funds to the manager
     *   3. Cap deposits
     * @param caller The address calling the deposit
     * @param receiver The address receiving the shares
     * @param assets The amount of assets being deposited
     * @param shares The amount of shares being minted
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        uint256 newTotal = _totalAssets + assets;
        if (newTotal > depositCap) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxDeposit(receiver));
        }

        super._deposit(caller, receiver, assets, shares);
        _totalAssets = newTotal;
        SafeERC20.safeTransfer(IERC20(asset()), manager, assets);
    }

    /**
     * @dev Override of _withdraw to track totalAssets explicitly and transfer funds to the manager
     * @param caller The address calling the withdrawal
     * @param receiver The address receiving the assets
     * @param owner The address owning the shares
     * @param assets The amount of assets being withdrawn
     * @param shares The amount of shares being burned
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
        nonReentrant
    {
        if (withdrawalsDisabled) revert ERC4626ExceededMaxWithdraw(owner, assets, 0);

        super._withdraw(caller, receiver, owner, assets, shares);
        _totalAssets -= assets;
    }

    /**
     * @dev Set the manager. Manager deploys deposited asset()
     * to generate yield
     * @param _manager The new fee recipient address
     */
    function setManager(address _manager) external onlyOwner {
        if (_manager == address(0)) revert InvalidManager();

        manager = _manager;
        emit ManagerUpdated(_manager);
    }

    /**
     * @dev Enables or disables withdrawals from the vault.
     * Can only be called by the contract owner.
     * Emits a {WithdrawalsDisabledUpdated} event.
     * @param _withdrawalsDisabled Boolean indicating if withdrawals should be disabled.
     */
    function setWithdrawalsDisabled(bool _withdrawalsDisabled) external onlyOwner {
        withdrawalsDisabled = _withdrawalsDisabled;
        emit WithdrawalsDisabledUpdated(_withdrawalsDisabled);
    }

    /**
     * @dev Set the deposit cap for the vault.
     * Can only be called by the contract owner.
     * @param _depositCap The new deposit cap in asset units.
     */
    function setDepositCap(uint256 _depositCap) external onlyOwner {
        depositCap = _depositCap;
        emit DepositCapUpdated(_depositCap);
    }
}
