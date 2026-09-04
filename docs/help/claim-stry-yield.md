# Claiming your STRY yield

STRY holders now earn weekly USDS yield automatically, distributed through [Merkl](https://app.merkl.xyz) — no staking required.

## What it does

Every week, USDS yield is deposited into a Merkl rewards campaign. Merkl tracks STRY balances directly and splits the week's yield pro-rata across holders, based on how much STRY they held and for how long during that week.

## How to get it

1. Hold STRY in your wallet. That's the only action required — there is no staking step, no position token, and nothing to approve.
2. Go to [app.merkl.xyz](https://app.merkl.xyz) and connect your wallet.
3. Find your claimable STRY rewards and claim them.

Rewards usually become claimable within 8–12 hours after each week's yield is deposited. A 3% Merkl protocol fee is deducted from each week's amount before it's distributed.

Note: wallets that can't call `claim()` on Merkl's Distributor contract — for example some liquidity pool contracts — will accrue rewards they can't collect unless they're excluded from the campaign.
