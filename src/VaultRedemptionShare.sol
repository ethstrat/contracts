// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {MintableBurnableToken} from "./MintableBurnableToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title STRAT perpetual debt receipt token
 */
contract VaultRedemptionShare is MintableBurnableToken {
    mapping(address => uint256) public redeemOffsetOf;
    mapping(address => uint256) public redeemedBy;
    mapping(address => uint256) public accClaimPerShareOnMint;

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
    event ClaimTransferred(
        address indexed from,
        address indexed to,
        uint256 fromRedeemOffset,
        uint256 toRedeemOffset,
        uint256 redeemOffsetTransfer,
        uint256 fromRedeemedBy,
        uint256 toRedeemedBy,
        uint256 redeemedByTransfer
    );

    error ClaimableExceedsBalance();

    /// @notice Returns the maximum amount of tokens that can be redeemed by a given owner.
    /// @param owner The address of the token owner.
    /// @return amount The maximum redeemable token amount for the specified owner.
    function maxRedeemableBy(address owner) public view returns (uint256 amount) {
        if (totalClaimableShares == 0) {
            return 0;
        }

        amount = (balanceOf(owner) * accClaimPerShare / 1e18);
        if (amount < redeemOffsetOf[owner]) {
            amount = 0;
        } else {
            amount -= redeemOffsetOf[owner];
        }

        /// NOTE: It's possible this contract has more redeemable tokens than totalClaimableShares,
        ///       as increasing redeemable tokens is permisionless. This check ensures the invariant
        ///       that one share is always equal to one redeemable token.
        if (amount > balanceOf(owner)) {
            amount = balanceOf(owner);
        }
    }

    /**
     * @notice Redeems the maximum amount of tokens available for the caller.
     * @dev This function always withdraws the maximum possible amount for the caller (`owner`)
     *      and sends the redeemed assets to the specified `receiver`.
     *      1 redemption share is always equal to 1 redeemable token
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
        redeemedBy[owner] += amount;
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
        uint256 grossOffset = ((amount * accClaimPerShare) + (1e18 - 1)) / 1e18;
        if (grossOffset < redeemedBy[owner]) {
            grossOffset = redeemedBy[owner];
        }
        redeemOffsetOf[owner] += grossOffset - redeemedBy[owner];
        totalClaimableShares += amount;
    }

    /// @notice Increases the claimable amount of redeemable tokens.
    /// @param amount The amount of redeemable tokens to increase the claimable amount by.
    /// @dev This function allows the contract to receive redeemable tokens and update the
    ///      accumulated claim per share. It can only be called by anyone. It will fail if there
    ///      are no claimable shares, however, given that code path will never be used, it is not a concern.
    function increaseClaimableAmount(uint256 amount) external {
        SafeERC20.safeTransferFrom(redeemableToken, msg.sender, address(this), amount);
        accClaimPerShare += (amount * 1e18) / totalClaimableShares;
    }

    function _update(address from, address to, uint256 value) internal override {
        // TODO needs some testing. What if from == to, to == 0?
        if (from != address(0) && to != address(0) && balanceOf(from) > 0) {
            // Transfer claimed proportionally to shares transferred
            // XXX: if balance is split on multiple accouts (2 - inf) is there leakage?
            uint256 redeemOffsetTransfer = redeemOffsetOf[from] * value / balanceOf(from);
            uint256 redeemedByTransfer = redeemedBy[from] * value / balanceOf(from);

            redeemOffsetOf[to] += redeemOffsetTransfer;
            redeemOffsetOf[from] -= redeemOffsetTransfer;
            redeemedBy[to] += redeemedByTransfer;
            redeemedBy[from] -= redeemedByTransfer;

            emit ClaimTransferred(
                from,
                to,
                redeemOffsetOf[from],
                redeemOffsetOf[to],
                redeemOffsetTransfer,
                redeemedBy[from],
                redeemedBy[to],
                redeemedByTransfer
            );
        }
        super._update(from, to, value);
    }
}
