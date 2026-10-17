#!/usr/bin/env node
// Monday go-live (19 Oct 2026) as ONE main-Safe tx at nonce 232: all golive-2 txs, then all liquidity txs.
// Reuses the tx lists + preflights of generate-golive-2.mjs and generate-golive-liquidity.mjs (imported = they run).
// Funding is NOT in the batch: fund 0xaA1A with >= 400,000 USDS and 0x0cbe with >= 150,000 USDS before execution; the
// liquidity generator WARNs when underfunded and the merged stateOverrides make the Tenderly sim work anyway.
// Usage: node --env-file=.env script/safe/generate-golive-monday.mjs [--dry-run]
// Writes golive-monday.json (+ .tx-builder.json) and golive-monday.seaport-order.json (order for sellers).
import { writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { parseArgs } from "node:util";
import { computeHashes, printHashes } from "./lib/safe-hash.mjs";
import { SAFE, transactions as tx2, added } from "./generate-golive-2.mjs";
import { transactions as txLiq, overrides, order, orderHash, counter, ask, SEAPORT } from "./generate-golive-liquidity.mjs";

const NONCE = 232n;
const { values: a } = parseArgs({ options: { "dry-run": { type: "boolean" } } });
const out = "script/safe/batches/golive-monday.json";
const orderFile = out.replace(/\.json$/, ".seaport-order.json");
const transactions = [...tx2, ...txLiq];
const batch = {
    description: "Monday go-live (19 Oct 2026 02:00 UTC), single tx at main Safe nonce 232: raise CDT debt cap to 11,000,000, make stETH redeemable from esETH, raise esETH allowances to the note to 100 from each holdings Safe"
        + (added.length ? `, add ${[...new Set(added)].join(", ")} as tripwire operator` : "")
        + "; then 400,000 USDS single-sided CDT/USDS Uniswap v4 LP ($1 down to ~$0) from the liquidity Safe, and a validated Seaport bid for CDT at $0.70 (150,000 USDS) from the redemption Safe"
        + `. Seaport order for sellers: ${orderFile} (orderHash ${orderHash}). BCF is already 0.25 on-chain, so no setBCF.`,
    safeAddress: SAFE,
    chainId: 1,
    transactions,
    ...(Object.keys(overrides).length ? { stateOverrides: overrides } : {}),
};
batch.hashes = await computeHashes(batch, { rpcUrl: process.env.RPC_URL, nonce: NONCE });
transactions.forEach((t, i) => console.log(`${i + 1}. ${t.label}`));
if (a["dry-run"]) {
    console.log(JSON.stringify(batch, null, 2));
    process.exit(0);
}
writeFileSync(out, JSON.stringify(batch, null, 2) + "\n");
writeFileSync(orderFile, JSON.stringify({ orderHash, seaport: SEAPORT, fill: "fulfillAdvancedOrder with denominator 1000000000", components: { ...order, counter } }, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
console.log(`wrote ${out} (${transactions.length} txs) and ${orderFile}; ask ${ask}`);
printHashes(batch.hashes);
const r = spawnSync("node", ["script/safe/export-tx-builder.mjs", out], { stdio: "inherit" });
if (r.status) process.exit(r.status);
