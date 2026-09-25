# Trading EARN for USDS

EARN trades against USDS in a Uniswap V4 pool.

## What it does

The pool opens at 100 USDS per EARN. It holds liquidity across the full price range, plus USDS that buys EARN between 50 and 100 USDS per EARN. Every swap pays a 0.30% pool fee plus a Uniswap protocol fee of up to 0.05%. The pool's liquidity positions are owned by the redemption Safe.

## How to get to it

Use any interface that routes Uniswap V4 swaps. Select EARN and USDS as the pair. The pool is the EARN/USDS V4 pool with a 0.30% fee tier and no hook.

## Steps

1. Connect your wallet on Ethereum mainnet.
2. Choose EARN as the token to sell and USDS as the token to receive, or the reverse.
3. Check that the route uses the EARN/USDS V4 pool at the 0.30% fee tier.
4. Enter the amount, review the price and fees, and confirm the swap.

EARN in your wallet earns no yield. Only staked EARN earns yield — see [How to earn EARN yield](claim-earn-yield.md).
