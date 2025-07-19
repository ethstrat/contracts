// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {MintableBurnableToken} from "./MintableBurnableToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title STRAT perpetual debt receipt token
 */
contract GammaVaultExitQueueToken is MintableBurnableToken {
    mapping(address => uint256) public totalClaimedBy;
    IERC20 public immutable withdrawableToken;

    constructor(address owner, IERC20 withdrawableToken_)
        MintableBurnableToken("ETH Strategy Vault Redemption Share", "VRS", owner)
    {
        withdrawableToken = withdrawableToken_;
    }

    event Withdraw(address indexed receiver, address indexed owner, uint256 assets);
    event ClaimedTransferred(
        address indexed from,
        address indexed to,
        uint256 fromClaimedTotal,
        uint256 toClaimedTotal,
        uint256 transferredAmount
    );

    error InsufficientWithdrawableAssets(uint256 requested, uint256 available);

    function maxWithdrawableBy(address owner) public view returns (uint256) {
        uint256 totalWithdrawableAssets = withdrawableToken.balanceOf(address(this)) * balanceOf(owner) / totalSupply();
        return totalWithdrawableAssets - totalClaimedBy[owner];
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxWithdrawable = maxWithdrawableBy(owner);

        if (assets > maxWithdrawable) {
            revert InsufficientWithdrawableAssets(assets, maxWithdrawable);
        }

        if (assets == 0) {
            assets = maxWithdrawable;
        }

        // If asset() is ERC-777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(owner, assets);
        totalClaimedBy[owner] += assets;
        SafeERC20.safeTransfer(withdrawableToken, receiver, assets);
        emit Withdraw(receiver, owner, assets);

        return assets;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) {
            uint256 claimTransfer = totalClaimedBy[from] * value / balanceOf(from);
            if (value == balanceOf(from)) {
                claimTransfer = totalClaimedBy[from];
            }

            totalClaimedBy[to] += claimTransfer;
            if (totalClaimedBy[from] < claimTransfer) {
                totalClaimedBy[from] = 0;
            } else {
                totalClaimedBy[from] -= claimTransfer;
            }

            emit ClaimedTransferred(from, to, totalClaimedBy[from], totalClaimedBy[to], claimTransfer);
        }

        super._update(from, to, value);
    }
}
