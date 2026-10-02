// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {StakedStrat} from "./StakedStrat.sol";
import {ITripwireController} from "./interfaces/ITripwireController.sol";
import {TripwireGuard} from "./lib/TripwireGuard.sol";

/**
 * @title Wrapped Staked EARN (wsEARN)
 * @notice ERC-4626 vault over EARN. Every EARN deposited is staked in `StakedStrat` on the vault's behalf, so the
 *         vault earns the USDS yield that sEARN holders get, while wsEARN itself stays a plain transferable token
 *         (sEARN is non-transferable, so it cannot be collateral). Yield is compounded in EARN terms:
 *         `harvest()` claims the USDS and forwards it to the owner (the Safe); the Safe buys EARN on the market
 *         and `donate()`s it back, which raises the EARN value of every wsEARN without minting shares.
 *         1 wsEARN starts at 1 EARN and only ever grows.
 * @dev `totalAssets()` is the vault's staked balance, never its EARN token balance, so EARN sent directly to the
 *      vault does not move the share price. The only way to raise the share price is `donate()`, which is owner
 *      only. That is what makes the classic ERC-4626 inflation attack impossible here, with no decimals offset.
 *      `depositCap` bounds total EARN under management while the contract is unaudited.
 */
contract WrappedStakedEarn is ERC4626, Ownable2Step, TripwireGuard {
    using SafeERC20 for IERC20;

    StakedStrat public immutable staking;
    IERC20 public immutable usds;

    /// @notice Maximum EARN the vault will hold (staked). Owner adjustable.
    uint256 public depositCap;

    event Harvested(uint256 usdsAmount);
    event Donated(uint256 earnAmount);
    event DepositCapSet(uint256 oldCap, uint256 newCap);

    error ZeroAddress();
    error ZeroAmount();
    error AssetMismatch();

    constructor(
        StakedStrat staking_,
        uint256 depositCap_,
        address owner_,
        ITripwireController controller_,
        address guardian_
    )
        ERC20("Wrapped Staked EARN", "wsEARN")
        ERC4626(staking_.stratToken())
        Ownable(owner_)
        TripwireGuard(controller_, guardian_)
    {
        if (address(staking_) == address(0)) revert ZeroAddress();
        staking = staking_;
        usds = staking_.rewardToken();
        if (address(usds) == asset()) revert AssetMismatch();
        depositCap = depositCap_;
        // One-time, unbounded: the vault only ever stakes what it has just received from a depositor or the owner.
        IERC20(asset()).forceApprove(address(staking_), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------------------
    // ERC-4626 accounting
    // ---------------------------------------------------------------------------------------------------------

    /// @inheritdoc ERC4626
    /// @dev Staked balance only. Loose EARN in this contract is not counted, so it cannot move the share price.
    function totalAssets() public view override returns (uint256) {
        return staking.staked(address(this));
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        uint256 assets = totalAssets();
        return assets >= depositCap ? 0 : depositCap - assets;
    }

    /// @inheritdoc ERC4626
    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /// @dev Pull EARN and mint shares (super), then stake it. Shares were priced before the stake, so the
    ///      depositor is not credited for their own deposit twice.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        staking.stake(assets);
    }

    /// @dev Unstake first so the EARN is here to send. `unstake` also pays any pending USDS to this contract;
    ///      it stays here until the next `harvest()`.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        staking.unstake(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Entry points, pausable via tripwire
    // ---------------------------------------------------------------------------------------------------------

    function deposit(uint256 assets, address receiver) public override whenNotTripped returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override whenNotTripped returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotTripped
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override whenNotTripped returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Yield cycle
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Claim the vault's USDS yield from staking and forward all USDS held to the owner. Permissionless:
    ///         the only destination is the owner.
    function harvest() external whenNotTripped returns (uint256 amount) {
        staking.claim();
        amount = usds.balanceOf(address(this));
        if (amount > 0) usds.safeTransfer(owner(), amount);
        emit Harvested(amount);
    }

    /// @notice Owner adds EARN to the vault without minting shares, raising the EARN value of every wsEARN.
    ///         This is how harvested USDS, once swapped to EARN by the Safe, is returned to holders.
    function donate(uint256 amount) external onlyOwner whenNotTripped {
        if (amount == 0) revert ZeroAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        staking.stake(amount);
        emit Donated(amount);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------------------

    function setDepositCap(uint256 newCap) external onlyOwner {
        emit DepositCapSet(depositCap, newCap);
        depositCap = newCap;
    }

    /// @notice Recover tokens sent here outside the deposit flow. EARN swept this way was never staked, so it was
    ///         never part of `totalAssets()` and no holder is affected.
    function sweep(IERC20 token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, token.balanceOf(address(this)));
    }
}
