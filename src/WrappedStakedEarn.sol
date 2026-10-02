// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
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
 * @dev `totalAssets()` is derived from `managedAssets`, an internal counter that only deposits, withdrawals and
 *      `donate()` move. It is deliberately not the vault's EARN balance and not `staking.staked(vault)`: anyone
 *      can transfer EARN here or `StakedStrat.migrateStake` onto the vault, and neither may move the share price.
 *      The only way to raise the share price is `donate()`, which is owner only. That is what makes the classic
 *      ERC-4626 inflation attack impossible here, with no decimals offset.
 *      Donations vest linearly over `VESTING_DURATION`, so a deposit made just before a donation and redeemed
 *      just after captures nothing; yield goes to whoever holds while it vests.
 *      `depositCap` bounds total EARN under management while the contract is unaudited.
 */
contract WrappedStakedEarn is ERC4626, Ownable2Step, TripwireGuard {
    using SafeERC20 for IERC20;

    /// @notice Period over which each donation is released into the share price. Matches the staking stream.
    uint256 public constant VESTING_DURATION = 28 days;

    StakedStrat public immutable staking;
    IERC20 public immutable usds;

    /// @notice Maximum EARN the vault will hold (staked). Owner adjustable.
    uint256 public depositCap;

    /// @notice EARN staked on behalf of holders: deposits plus donations, less withdrawals. Includes the part of
    ///         past donations that has not vested yet.
    uint256 public managedAssets;

    /// @notice Donated EARN that was still unvested at the last `donate()`, and when it finishes vesting.
    uint256 public vestingAmount;
    uint256 public vestingEnd;

    event Harvested(uint256 usdsAmount);
    event Donated(uint256 earnAmount);
    event DepositCapSet(uint256 oldCap, uint256 newCap);
    event ExcessStakeSwept(address indexed to, uint256 earnAmount);

    error ZeroAddress();
    error ZeroAmount();
    error AssetMismatch();
    error NoShares();
    error RenounceDisabled();

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
    /// @dev Managed EARN less the unvested part of donations. Loose EARN in this contract and stake migrated onto
    ///      it from outside are not counted, so neither can move the share price.
    function totalAssets() public view override returns (uint256) {
        return managedAssets - unvestedAssets();
    }

    /// @notice Donated EARN not yet released into the share price. Rounded up, in the vault's favour.
    function unvestedAssets() public view returns (uint256) {
        uint256 end = vestingEnd;
        if (block.timestamp >= end) return 0;
        return Math.mulDiv(vestingAmount, end - block.timestamp, VESTING_DURATION, Math.Rounding.Ceil);
    }

    /// @notice Whether wsEARN can currently be redeemed for EARN, i.e. neither `redeem` here nor `unstake` on
    ///         the staking contract is tripped. The Morpho oracle refuses to quote while this is false.
    function redeemable() public view returns (bool) {
        return !_tripped(this.redeem.selector) && !_stakingTripped(staking.unstake.selector);
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        if (_tripped(this.deposit.selector) || _stakingTripped(staking.stake.selector)) return 0;
        return _capHeadroom();
    }

    /// @inheritdoc ERC4626
    function maxMint(address) public view override returns (uint256) {
        if (_tripped(this.mint.selector) || _stakingTripped(staking.stake.selector)) return 0;
        return convertToShares(_capHeadroom());
    }

    /// @inheritdoc ERC4626
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (_tripped(this.withdraw.selector) || _stakingTripped(staking.unstake.selector)) return 0;
        return super.maxWithdraw(owner);
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override returns (uint256) {
        if (!redeemable()) return 0;
        return super.maxRedeem(owner);
    }

    /// @dev Pull EARN and mint shares (super), then stake it. Shares were priced before the stake, so the
    ///      depositor is not credited for their own deposit twice.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        if (assets == 0) return;
        managedAssets += assets;
        staking.stake(assets);
    }

    /// @dev Unstake first so the EARN is here to send. `unstake` also pays any pending USDS to this contract;
    ///      it stays here until the next `harvest()`.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (assets != 0) {
            managedAssets -= assets;
            staking.unstake(assets);
        }
        super._withdraw(caller, receiver, owner, assets, shares);
        // Nobody is left to own what remains (unvested donations, rounding dust). Drop it from the accounting so
        // the next depositor starts at 1:1 again; it stays staked and the owner can `sweepExcessStake` it.
        if (totalSupply() == 0) {
            managedAssets = 0;
            vestingAmount = 0;
            vestingEnd = 0;
        }
    }

    function _capHeadroom() private view returns (uint256) {
        uint256 managed = managedAssets;
        return managed >= depositCap ? 0 : depositCap - managed;
    }

    function _tripped(bytes4 selector) private view returns (bool) {
        return this.controller().isTripped(address(this), selector);
    }

    function _stakingTripped(bytes4 selector) private view returns (bool) {
        return staking.controller().isTripped(address(staking), selector);
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
    /// @dev The share price does not move in this call. The donation, together with whatever is still unvested
    ///      from earlier ones, is released linearly over the next `VESTING_DURATION`.
    function donate(uint256 amount) external onlyOwner whenNotTripped {
        if (amount == 0) revert ZeroAmount();
        if (totalSupply() == 0) revert NoShares();
        vestingAmount = unvestedAssets() + amount;
        vestingEnd = block.timestamp + VESTING_DURATION;
        managedAssets += amount;
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

    /// @notice Recover EARN staked on the vault's account that it does not manage: stake migrated onto it from
    ///         outside, or what was left behind when the last wsEARN was redeemed. Never part of `totalAssets()`.
    function sweepExcessStake(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 excess = staking.staked(address(this)) - managedAssets;
        if (excess == 0) revert ZeroAmount();
        staking.unstake(excess);
        IERC20(asset()).safeTransfer(to, excess);
        emit ExcessStakeSwept(to, excess);
    }

    /// @dev Disabled. `harvest()` pays the owner and only the owner can `donate()`, so the vault cannot run
    ///      without one.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
