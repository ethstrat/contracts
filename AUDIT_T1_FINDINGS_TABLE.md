# T1 audit — finding index (summary)

| Scope | Summary | Status | Notes |
|--------|---------|--------|-------|
| TripwireController | Inaccurate NatSpec: guardians cannot reset (actually can) | Fixed | NatSpec corrected. Tripwire still pauses guarded functions when tripped; |
| TripwireController | `onlyOperator` modifier defined but unused | Ack | Informational (size). Pause/response story unchanged; |
| EthStrategyConvertibleNote | Governance: no on-chain bounds for GCF/PCF | Ack | Multisig timelocks after launch. |
| EthStrategyConvertibleNote | DoS risk: shortfall pulls from encumbered → insolvent encumbered / broken conversions | Ack/Partially fixed | By design: can only sweep **expired** options; after expiry as encumbered and unencumbered are **unambiguously** the same pool. Removed the automatic sweep, but kept the owner/permissioned sweep |
| EthStrategyConvertibleNote | Conversion rates depend on manipulable on-chain inputs (GAV, supplies, oracle) | Ack | Report Acknowledged; risk assessment / ops. By Design |
| EthStrategyConvertibleNote | Rounding direction in conversion rate math inflates entitlements | Ack | Report Acknowledged; economic assessment. |
| EthStrategyConvertibleNote | STRAT book value vs encumbered + CDT liability (design) | disputed | This is specifically reffering to the calculate of gav (gross asset value) which shouldn't account for debt, minting STRAT on conversion is designed to be provably accreative diluation, and this audit is specifically scoped to not include treasury lend |
| EthStrategyConvertibleNote | stETH depeg vs ETH oracle / bonding incentives | ack/discputed | Report Acknowledged on solvency check point (by design). nobody would provide ETH to get an equivalent of esETH is not relevant as notes are long term instruments (this assumes stETH won't regain peg via exit queue, which practically has never been the case) |
| EthStrategyConvertibleNote | Post-bond STRAT price / self–price impact | Ack | Report Acknowledged; design inherent. |
| EthStrategyConvertibleNote | `expiry == block.timestamp`: convert and redeem both allowed; `releaseEncumbrance` interaction | Fixed | |
| EthStrategyConvertibleNote | Insolvency: commingled accounting / proportional payout vs option backing | Ack | **By design:** single commingled pool and payout in insolvency / recovery; not an oversight. Auditors **Low** (downgraded once intent was clear). Tradeoff accepted. |
| EthStrategyConvertibleNote | Initial STRAT bonding price vs external market | Ack | Report Acknowledged; deployment params. |
| EthStrategyConvertibleNote | Public CDT burn → zero supply breaks conversion early-return | Ack | Report Acknowledged; could pause burn/Protocol will hold some CDT on launch to mitigate |
| EthStrategyConvertibleNote | `premiumUSD` not tied to solvency ratio (nominal debt) | Ack | Report Acknowledged. Linear simpler and more conservative for autonomous bond pricing |
| EthStrategyConvertibleNote | Split bonds vs one bond: different aggregate entitlements | Ack | Report Acknowledged. Design trade off for simplicity in pricing |
| EthStrategyConvertibleNote | Solvency check `treasuryInUSD > debt`: off-by-one vs `>=` | Ack | Report Acknowledged.|
| EthStrategyConvertibleNote | Bond: second `wrapAndMint` can be zero → revert | Ack | Report Acknowledged. |
| EthStrategyConvertibleNote | `convertWithPermit` / redeem permit frontrun griefing | Ack | Report Acknowledged; other entrypoints exist. |
| EthStrategyConvertibleNote | ETH/USD decline vs USD-notional redemption economics | Ack | Report Acknowledged; design. |
| EthStrategyConvertibleNote | Haircut on esETH/STRAT entitlements even when premium zero | Ack | Report Acknowledged; design. |
| EthStrategyConvertibleNote | Bond: no min/slippage on CDT amount (oracle moves) | Ack | Report Acknowledged. |
| EthStrategyConvertibleNote | Redemption: redundant `timelock` check given `expiry` | Ack | Report Acknowledged. |
| EthStrategyConvertibleNote | Constructor: no `encumberedHoldings != unencumberedHoldings` | Ack | Will handle during deployment |
| EthStrategyConvertibleNote | `conversionEntitlements`: `(0,0)` if STRAT supply or total ETH zero | Ack | STRAT minted so won't be an issue during deployment |
| EthStrategyConvertibleNote | Redemption sets `encumbranceReleased` false after burn (dead storage) | Ack | changed to delete to be semanticly correct |
| EthStrategyConvertibleNote | Bond: redundant `timelock` / `expiry` validation (fixed offsets) | ack ||
| EthStrategyConvertibleNote | Donation of esETH to holdings can flip solvency branch | Ack | |
| EthStrategyConvertibleNote | Convert with zero entitlement still burns CDT (user mistake) | Ack | |
| EthStrategyConvertibleNote | Tripwire: wrapper selector vs inner `convertPartialWithPermit` / `syncRewards` | Ack | |
| esETH | Governance: arbitrary `tokenConfig` / treasury manager risk | Ack | Report Acknowledged; multisig. |
| esETH | LST rate can fall after mint → phantom / cross-asset esETH | Ack | Acceptable risk; tripwire pauses on unfavorable rate change until policy set. |
| esETH | Redeem burn: +1 wei insufficient for wstETH/rETH double floor | Resolved | Appendix: use `getStETHByWstETH` / `getEthValue`; slim token set in `contracts`. |
| esETH | JIT yield theft via rebase; no mint/redeem fee | Ack | Same risk bucket as rate / yield; ops / future fee. |
| esETH | stETH / weETH depeg vs internal conversion rates | Ack | Report Acknowledged. |
| esETH | ERC20 LST decimals not normalized to 18 | Ack | Report Acknowledged; governance whitelist. |
| esETH | `harvestYield` can mint while another bucket loses (asymmetric) | Ack | |
| esETH | Very small mint/redeem amounts → rounding edge cases | Ack | Report Acknowledged. |
| esETH | Slippage-free “swaps” by mint/redeem across LSTs | Ack | Report Acknowledged. |
| esETH | No rate limits across LST mint paths | Ack | Report Acknowledged. |
| esETH | No incentive to call `burnExcess` | Ack | Report Acknowledged. |
| esETH | +1 wei redeem dust vs `harvestYield` accounting | Ack | Practical dust minimal. |
| esETH | Phantom “yield” from floor rounding vs `harvestYield` aggregate | Ack | Report Acknowledged. |
| StakedStrat | Rewards streamed while `totalStaked == 0` → rewards stranded | Ack | First deposit on deploy to mitigate related edge cases. |
| StakedStrat | Integer truncation strands reward dust (rate, RPS, claim) | Ack | Report Acknowledged; esETH 18 decimals. |
| StakedStrat | `PRECISION` 1e18 insufficient for some token decimals / stake sizes | Ack | Report Acknowledged. |
| StakedStrat | `migrateStake` force-claims rewards on `to` (tax / surprise) | Ack | Report Acknowledged. |
| StakedStrat | Deposit reward-debt split → dust extraction edge case | Ack | Report Acknowledged. |
| StakedStrat | Negative rebase on reward token + `syncRewards` accounting | Ack | Report Acknowledged; avoid rebasing reward token. |
| StakedStrat | `rewardToken == stakeToken` can mis-account deposits as rewards | Fixed | Constructor guard: `require(_stratToken != _rewardToken)`. |
| StakedStrat | Migration moves sSTRAT despite non-transferable design | Ack | Report Acknowledged; same as stake flow. |
| StakedStrat | `migrateStake` rewardDebt math underflow edge case | Ack | |
| StakedStrat | Reward token blacklist → unstake reverts, principal stuck | Ack | |
| Global | No global `Pausable` (only tripwire per contract) | Ack | by design |
| Global | Not compatible with fee-on-transfer tokens | Ack | won't use fee-on-transfer tokens|
| MintableBurnableToken | Owner can add arbitrary minters (supply dilution) | Ack | Report Acknowledged; multisig. |