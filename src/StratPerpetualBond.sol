// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Strat Perpetual Bond 
 * @dev Eth Strategy perpetual bond. A defi version of MSTR's preferred stock
 *      The vault is designed to allow flexibility w.r.t the underlying strategy
 *      (owners can set the manager)
 */
contract StratPerpetualBond is ERC4626, Ownable2Step, ReentrancyGuard {
    using Math for uint256;

    address public manager;
    
    uint256 private _totalAssets;
    
    /// @dev Maximum total assets that can be deposited (0 = no cap)
    uint256 public depositCap;

    /// @dev Withdrawals are disabled by default. Exit is via LP
    bool public withdrawalsDisabled = true;

    /// @dev Events
    event ManagerUpdated(address indexed newManager);
    event WithdrawalsDisabledUpdated(bool isWithdrawalsDisabled);
    event DepositCapUpdated(uint256 newCap);

    /// @dev Errors
    error InvalidManager();
    error WithdrawalsDisabled();

    /**
     * @dev Constructor for the vault
     * @param _asset The underlying ERC20 token for the vault
     * @param _owner The owner of the vault
     */
    constructor(
        IERC20 _asset,
        address _owner
    ) ERC4626(_asset) ERC20("STRAT Perpetual Bond", "SPB") Ownable(_owner) {
    }

    /** @dev See {IERC4626-totalAssets}. */
    function totalAssets() public view virtual override returns (uint256) {
        return _totalAssets;
    }

    function increaseAssetsPerShare(uint256 assets) external {
        SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), assets);
        SafeERC20.safeTransfer(IERC20(asset()), manager, assets);
        _totalAssets += assets;
    }

    function maxDeposit(address) public view virtual override returns (uint256) {
        return depositCap > _totalAssets ? depositCap - _totalAssets : 0;
    }

    function maxMint(address) public view virtual override returns (uint256) {
        return previewDeposit(maxDeposit(address(0)));
    }

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
     * @dev Override of _deposit to 
     *   1. track totalAssets explicitly 
     *   2. transfer funds to the manager
     *   3. Cap deposits
     * @param caller The address calling the deposit
     * @param receiver The address receiving the shares
     * @param assets The amount of assets being deposited
     * @param shares The amount of shares being minted
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
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
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override nonReentrant {
        if (withdrawalsDisabled) revert WithdrawalsDisabled();

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