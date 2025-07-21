// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {VaultRedemptionToken} from "./VaultRedemptionToken.sol";

/**
 * @title GammaVault
 * @dev ERC4626-compliant vault for with time-based yield distribution.
 *      - Allows deposits in a specified deposit token, forwarding them to a treasury.
 *      - Yield is added by a designated yield manager and released linearly over time.
 *      - Integrates with VaultRedemptionToken, for proportional withdrawals
 *      - Owner can set the yield manager.
 *      - Reentrancy considerations are addressed in deposit and withdrawal flows.
 *
 * @custom:security
 * - Uses SafeERC20 for token transfers.
 * - Handles ERC-777 reentrancy scenarios in deposit/withdrawal.
 *
 * @custom:errors
 * - YieldManagerUnauthorizedAccount: Thrown when a non-yield manager attempts to add yield.
 *
 * @param vaultTreasury Address receiving deposited tokens.
 * @param depositToken ERC20 token accepted for deposits.
 * @param yieldManager Address authorized to add yield.
 * @param ratePerSecond Current yield release rate per second (scaled by 1e18).
 * @param lastUpdated Timestamp of last yield accounting update.
 * @param totalUnreleasedYield Total yield yet to be released.
 */
contract GammaVault is ERC4626, Ownable2Step {
    address public immutable vaultTreasury;
    IERC20 public immutable depositToken;
    address public yieldManager;

    uint256 public ratePerSecond;
    uint256 public lastUpdated;
    uint256 public totalUnreleasedYield;

    error YieldManagerUnauthorizedAccount(address account);

    constructor(IERC20 asset_, IERC20 depositToken_, address vaultTreasury_, address owner_)
        Ownable(owner_)
        ERC4626(asset_)
        ERC20("ETH Strategy Vault Yield Share", "VYS")
    {
        vaultTreasury = vaultTreasury_;
        depositToken = depositToken_;
        yieldManager = owner_;

        // Suggestion: check that asset_.supportsInterface() for the VaultRedemptionToken interface

        // Suggestion: if owner_ is not the correct address, it will be a huge problem. Instead, default to deployer and
        // propose owner_ to be the new owner (requiring acceptance)
    }

    function setYieldManager(address newYieldManager) external onlyOwner {
        yieldManager = newYieldManager;

        // Suggestion: emit event
    }

    function addYield(uint256 amount, uint256 duration) external yieldManagerOnly {
        claimedUnreleasedYield();
        ratePerSecond += (amount * 1e18) / duration;
        totalUnreleasedYield += amount;
    }

    function claimedUnreleasedYield() public {
        uint256 unrealisedYield = unreleasedYield();
        totalUnreleasedYield -= unrealisedYield;
        lastUpdated = block.timestamp;
        VaultRedemptionToken(asset()).mint(address(this), unrealisedYield);
    }

    function unreleasedYield() public view returns (uint256) {
        uint256 elapsed = block.timestamp > lastUpdated ? block.timestamp - lastUpdated : 0;

        uint256 newAssets = elapsed * ratePerSecond / 1e18;
        if (totalUnreleasedYield < newAssets) {
            return totalUnreleasedYield;
        } else {
            return newAssets;
        }
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        claimedUnreleasedYield();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        claimedUnreleasedYield();
        return super.mint(shares, receiver);
    }

    // Override withdraw/redeem to update accounting
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        claimedUnreleasedYield();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        claimedUnreleasedYield();
        return super.redeem(shares, receiver, owner);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // If asset() is ERC-777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        SafeERC20.safeTransferFrom(depositToken, caller, address(this), assets);
        depositToken.transfer(vaultTreasury, depositToken.balanceOf(address(this)));
        _mint(receiver, shares);
        VaultRedemptionToken(asset()).mint(address(this), assets);
        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // If asset() is ERC-777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(owner, shares);
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        VaultRedemptionToken(asset()).increaseClaimableSharesFor(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @dev Throws if called by any account other than the yield manager.
     */
    modifier yieldManagerOnly() {
        if (msg.sender != yieldManager) {
            revert YieldManagerUnauthorizedAccount(msg.sender);
        }
        _;
    }
}
