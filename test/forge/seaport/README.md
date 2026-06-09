# Seaport Rage Quit Example

This directory contains a Foundry mainnet-fork test showing how Seaport can be used as a fixed-rate, partially-fillable ERC20 basket settlement mechanism.

The example models:

```text
Treasury offers: 3000 WETH
User pays:       STRAT + USDC
Fill amount:     chosen by the rage quitter
```

Useful references:

- Seaport overview: https://docs.opensea.io/docs/seaport
- Seaport models: https://docs.opensea.io/docs/seaport-models
- Seaport interface: https://docs.opensea.io/docs/seaport-interface
- Seaport hooks/zones: https://docs.opensea.io/docs/seaport-hooks
- Seaport repo: https://github.com/ProjectOpenSea/seaport

## Files

```text
ISeaportMinimal.sol
  Minimal interface for the deployed Seaport contract.

SeaportOrderLib.sol
  Helper for building the EIP-712 digest to sign.

SeaportRageQuit.t.sol
  End-to-end mainnet-fork test.
```

## Test setup

The test forks Ethereum mainnet at block `25282546`.

```text
STRAT:   0x14cF922aa1512Adfc34409b63e18D391e4a86A2f
WETH:    0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
USDC:    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
Seaport: 0x0000000000000068F116a894984e2DB1123eB395
```

Run:

```bash
MAINNET_RPC_URL="$MAINNET_RPC_URL" forge test \
  --match-contract SeaportRageQuitTest \
  -vvv
```

## High-level flow

There are two actor roles.

```text
Treasury:
  1. Holds WETH.
  2. Approves Seaport, or the chosen conduit, to spend WETH.
  3. Creates the fixed order terms.
  4. Signs the Seaport order.

Rage quitter:
  1. Chooses how much of the order to fill.
  2. Approves Seaport, or the chosen conduit, to spend STRAT and USDC.
  3. Builds AdvancedOrder with their chosen numerator / denominator.
  4. Calls fulfillAdvancedOrder().
```

The treasury signs the menu. The rage quitter chooses the portion.

The treasury signs fixed terms such as:

```text
3000 WETH is available.
The required payment is STRAT + USDC at a fixed ratio.
Partial fills are allowed.
The order expires at endTime.
```

The rage quitter chooses the fill fraction:

```solidity
numerator = 1;
denominator = 100;
```

That fills 1% of the original order.

The treasury does **not** sign or choose each fulfiller's numerator / denominator.

## Order shape

The order is:

```text
offer:
  - 3000 WETH from treasury

consideration:
  - TOTAL_STRAT_ASK STRAT to treasury
  - TOTAL_USDC_ASK USDC to treasury
```

The order type is:

```solidity
orderType = PARTIAL_OPEN;
```

That means anyone can partially fill the order.

`fulfillAdvancedOrder` is used because it supports partial fills. A normal `fulfillOrder` is simpler, but it fills the whole order.

## Key parameters

### `offerer`

```solidity
offerer = treasury;
```

The treasury is the account offering WETH.

The test uses a mock EOA treasury so it can sign directly. A production treasury is likely a Safe, which means using Safe EIP-1271 signatures or having the Safe call `Seaport.validate()`.

### `offer`

```solidity
offer = [3000 WETH];
```

The treasury pays WETH to rage quitters.

### `consideration`

```solidity
consideration = [STRAT to treasury, USDC to treasury];
```

The rage quitter pays both STRAT and USDC.

Sending STRAT to treasury proves settlement, but it does not burn STRAT. If the protocol needs burning or accounting, send STRAT to a redemption/burner contract instead.

### `orderType`

```solidity
orderType = PARTIAL_OPEN;
```

This allows public partial fills.

Use a restricted order type or a zone if only eligible users should be allowed to fill.

### `zone` and `zoneHash`

```solidity
zone = address(0);
zoneHash = bytes32(0);
extraData = "";
```

No zone is used. This keeps the order simple and public.

Use a zone for custom restrictions such as allowlists, Merkle proofs, or policy checks.

### `startTime` and `endTime`

```solidity
startTime = block.timestamp;
endTime = block.timestamp + 7 days;
```

This defines the rage-quit window.

### `salt`

```solidity
salt = uint256(...);
```

Seaport's deployed ABI uses `uint256 salt`, not `bytes32 salt`. Getting this wrong changes tuple-based function selectors.

### `conduitKey`

```solidity
conduitKey = bytes32(0);
fulfillerConduitKey = bytes32(0);
```

`bytes32(0)` means direct approvals to Seaport.

With a non-zero conduit key, approvals must go to the corresponding Seaport conduit instead.

### `totalOriginalConsiderationItems`

```solidity
totalOriginalConsiderationItems = consideration.length;
```

For this order it is `2`: STRAT and USDC.

### `recipient`

```solidity
recipient = address(0);
```

For `fulfillAdvancedOrder`, `address(0)` means the offered WETH goes to `msg.sender`, the rage quitter.

## Signing

`SeaportOrderLib` builds the digest by:

```text
1. Converting OrderParameters to OrderComponents.
2. Reading the offerer's Seaport counter.
3. Calling Seaport.getOrderHash(OrderComponents).
4. Calling Seaport.information() for the domain separator.
5. Building keccak256(0x1901 || domainSeparator || orderHash).
```

The signed order includes the fixed treasury terms and the current Seaport counter.

It does **not** include the rage quitter's fill `numerator / denominator`. That fraction is supplied later in `AdvancedOrder`.

## UI guidance

Do not make users think in percentages. Let the user enter an amount, usually:

```text
WETH amount to receive
```

Then derive the Seaport fill fraction:

```text
numerator   = desiredWethOut
denominator = TOTAL_WETH_OFFER
```

Reduce the fraction with GCD before submitting.

Example:

```text
desiredWethOut = 30 WETH
TOTAL_WETH_OFFER = 3000 WETH

30 / 3000 = 1 / 100
```

Then derive the required inputs:

```text
STRAT required = TOTAL_STRAT_ASK * numerator / denominator
USDC required  = TOTAL_USDC_ASK  * numerator / denominator
```

The fraction is always relative to the **original order size**, not the remaining order size.

If an order starts with 3000 WETH and 1500 WETH remains, a fill of:

```text
numerator = 1
denominator = 10
```

still means 10% of the original order, not 10% of the remaining order.

## UI metrics

Use `getOrderStatus(orderHash)` to get Seaport's fill/cancel state:

```solidity
(
    bool isValidated,
    bool isCancelled,
    uint256 totalFilled,
    uint256 totalSize
) = seaport.getOrderStatus(orderHash);
```

For a partially filled order:

```text
filled fraction    = totalFilled / totalSize
remaining fraction = (totalSize - totalFilled) / totalSize
```

For an untouched order, Seaport reports `0 / 0`. Treat this as:

```text
filled = 0
remaining = full order
```

The UI can derive:

```text
filled WETH    = TOTAL_WETH_OFFER * totalFilled / totalSize
remaining WETH = TOTAL_WETH_OFFER - filled WETH

remaining STRAT = TOTAL_STRAT_ASK - filled STRAT
remaining USDC  = TOTAL_USDC_ASK  - filled USDC
```

The UI should also check live token state:

```text
treasury WETH balance
treasury WETH allowance
user STRAT balance and allowance
user USDC balance and allowance
expiry
cancelled status
current Seaport counter validity
```

`getOrderStatus` does not tell you whether treasury has revoked allowance or moved WETH away.

## Numerator / denominator constraints

Seaport partial fills use:

```solidity
uint120 numerator;
uint120 denominator;
```

Every item must divide exactly by the selected fraction.

For a proposed fill:

```text
TOTAL_WETH_OFFER * numerator % denominator == 0
TOTAL_STRAT_ASK  * numerator % denominator == 0
TOTAL_USDC_ASK   * numerator % denominator == 0
```

If not, Seaport can revert with `InexactFraction`.

This matters especially for USDC because it has 6 decimals, not 18.

The UI should either:

```text
snap to valid increments
round down to the nearest valid amount
or reject amounts that cannot be filled exactly
```

## Cancellation and kill switches

There are several ways to stop fills. They are not equivalent.

### Explicit Seaport cancellation

The clean normal path is:

```solidity
seaport.cancel(orderComponents);
```

This marks the order hash as cancelled inside Seaport. Future fills revert even if balances and allowances are still present.

### Counter invalidation

```solidity
seaport.incrementCounter();
```

This invalidates outstanding signed orders for the offerer that used the previous counter.

Treat the counter as an opaque invalidation value. Do not assume it increments by exactly `1`.

### Expiry

The order becomes unfillable after `endTime`.

This is the passive safety bound every production order should have.

### Revoking WETH allowance

```solidity
IERC20(WETH).approve(SEAPORT, 0);
```

This makes fills fail because Seaport cannot pull WETH.

This is a useful emergency stop, but it is not true Seaport cancellation. If allowance is restored before expiry, the same signed order may become fillable again.

### Moving WETH away

Moving WETH out of treasury also makes fills fail.

This is another operational kill switch, not canonical cancellation.

## Main risks

### Fixed-ratio basket

Partial fills scale the whole order. The fulfiller cannot pay only STRAT or only USDC. They must pay both in the signed ratio.

### Public fillability

`PARTIAL_OPEN` means anyone can fill. If eligibility matters, use a zone, restricted order type, Merkle proof system, contract offerer, or dedicated redemption contract.

### Seaport is settlement, not rage-quit accounting

Seaport transfers tokens atomically. It does not:

```text
burn STRAT
calculate NAV
track per-user limits
enforce governance-specific eligibility
emit protocol-specific redemption events
```

Use a dedicated redemption contract if those semantics matter.

### MEV / fill competition

A public fulfillment transaction can be copied or beaten. That may be fine for a public tender offer, but not for user-specific entitlements.

### Non-standard ERC20s

This assumes normal ERC20 behavior. Be careful with fee-on-transfer, rebasing, pausable, blacklistable, or unusual upgradeable tokens.

## When Seaport fits

Seaport is a good fit when the rage-quit mechanism is:

```text
fixed-rate
fixed basket
publicly fillable
partial-fillable
time-bounded
atomic ERC20 settlement
```

Use a dedicated rage-quit/redemption contract when the mechanism needs:

```text
per-user limits
eligibility checks
NAV-based pricing
burning
custom accounting
claim tracking
anti-MEV protections
multiple settlement modes
```
