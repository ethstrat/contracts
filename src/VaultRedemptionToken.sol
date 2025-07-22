// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {MintableBurnableToken} from "./MintableBurnableToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title STRAT perpetual debt receipt token
 */
contract VaultRedemptionToken is MintableBurnableToken {
    mapping(address => uint256) public redeemOffsetOf;
    uint256 public totalClaimableShares;
    uint256 public accClaimPerShare;

    IERC20 public immutable redeemableToken;

    constructor(address owner, IERC20 redeemableToken_)
        MintableBurnableToken("ETH Strategy Vault Redemption Share", "VRS", owner)
    {
        redeemableToken = redeemableToken_;

        // Suggestion: check that redeemableToken has 18 decimals
    }

    event Redeem(address indexed receiver, address indexed owner, uint256 assets);
    event ClaimedTransferred(
        address indexed from,
        address indexed to,
        uint256 fromClaimedTotal,
        uint256 toClaimedTotal,
        uint256 transferredAmount
    );

    error ClaimableExceedsBalance();

    /// @notice Returns the maximum amount of tokens that can be redeemed by a given owner.
    /// @param owner The address of the token owner.
    /// @return The maximum redeemable token amount for the specified owner.
    function maxRedeemableBy(address owner) public view returns (uint256) {
        if (totalClaimableShares == 0) {
            return 0;
        }

        return (balanceOf(owner) * accClaimPerShare / 1e18) - redeemOffsetOf[owner];
    }

    /**
     * @notice Redeems the maximum amount of tokens available for the caller.
     * @dev This function always withdraws the maximum possible amount for the caller (`owner`)
     *      and sends the redeemed assets to the specified `receiver`.
     * @param receiver The address to receive the redeemed assets.
     * @param owner The address whose tokens will be redeemed.
     * @return The amount of assets redeemed.
     */
    function redeem(address receiver, address owner) public virtual returns (uint256) {
        uint256 amount = maxRedeemableBy(owner);
        if (amount == 0) {
            return 0;
        }

        if (amount > balanceOf(owner)) {
            amount = balanceOf(owner);
        }

        if (redeemableToken.balanceOf(address(this)) < amount) {
            amount = redeemableToken.balanceOf(address(this));
        }

        redeemOffsetOf[owner] += amount;
        _burn(owner, amount);
        totalClaimableShares -= amount;
        SafeERC20.safeTransfer(redeemableToken, receiver, amount);
        emit Redeem(receiver, owner, amount);

        return amount;
    }

    function increaseClaimableSharesFor(address owner, uint256 amount) external onlyMinter {
        if (amount > balanceOf(owner)) {
            revert ClaimableExceedsBalance();
        }

        // round up in favor of the vault
        redeemOffsetOf[owner] += ((amount * accClaimPerShare) + (1e18 - 1)) / 1e18;
        totalClaimableShares += amount;
    }

    function increaseClaimableAmount(uint256 amount) external {
        SafeERC20.safeTransferFrom(redeemableToken, msg.sender, address(this), amount);
        accClaimPerShare += (amount * 1e18) / totalClaimableShares;
    }

    function _update(address from, address to, uint256 value) internal override {
        // TODO needs some testing. What if from == to, to == 0?
        if (from != address(0) && balanceOf(from) > 0) {
            // Transfer claimed proportionally to shares transferred
            uint256 claimTransfer = redeemOffsetOf[from] * value / balanceOf(from);
            redeemOffsetOf[to] += claimTransfer;
            redeemOffsetOf[from] -= claimTransfer;
            emit ClaimedTransferred(from, to, redeemOffsetOf[from], redeemOffsetOf[to], claimTransfer);
        }
        super._update(from, to, value);
    }
}
