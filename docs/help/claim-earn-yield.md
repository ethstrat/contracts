# Earning and claiming EARN yield

EARN holders who stake their tokens earn USDS yield from the staking contract (`StakedStrat`), funded every 28 days.

## What it does

Staked EARN (sEARN) is minted 1:1 when you stake, and is non-transferrable. Every 28 days, USDS yield is transferred into the staking contract and streamed to stakers over the following 28 days, proportional to how much EARN each address has staked relative to the total staked. Holding EARN without staking it earns nothing.

## How to get it

1. Approve the staking contract to spend your EARN.
2. Call `stake(amount)` on the staking contract to deposit EARN and receive sEARN.
3. Check your pending rewards at any time by reading the contract's `getPendingRewards(yourAddress)` view.
4. Call `claim()` on the staking contract to withdraw your accrued USDS rewards, or call `unstake(amount)` to withdraw your staked EARN — unstaking automatically claims any pending rewards first.

Rewards accrue continuously over each 28-day stream, not all at once, so claiming earlier in the period pays out less than waiting until the stream finishes.

Note: wallets that can't call `claim()` — for example some liquidity pool contracts — will accrue rewards they can't collect if they hold staked EARN.
