#!/usr/bin/env node
// Compute (and optionally record/verify) the Safe tx hashes for any batch JSON (plain or tx-builder schema).
// Usage: node --env-file=.env script/safe/hash-batch.mjs <batch.json> [--nonce N] [--write | --check]
//   (default)  print hashes at the current on-chain nonce (or --nonce N)
//   --write    store them under top-level "hashes" in the batch JSON (deterministic, no timestamps)
//   --check    recompute at the recorded nonce; exit 1 if recorded hashes differ
// Nonce changes whenever another Safe tx executes first: re-run with --write (or --nonce N).
import { readFileSync, writeFileSync } from "node:fs";
import Safe from "@safe-global/protocol-kit";
import { parseArgs } from "node:util";
import { computeHashes, diffHashes, printHashes } from "./lib/safe-hash.mjs";

const { values: a, positionals: [path] } = parseArgs({
    allowPositionals: true,
    options: { nonce: { type: "string" }, write: { type: "boolean" }, check: { type: "boolean" } },
});
if (!path) throw new Error("usage: hash-batch.mjs <batch.json> [--nonce N] [--write|--check]");
if (!process.env.RPC_URL) throw new Error("set RPC_URL (node --env-file=.env)");
const batch = JSON.parse(readFileSync(path, "utf8"));

if (a.check) {
    if (!batch.hashes) throw new Error(`${path} has no recorded "hashes"`);
    const cur = await computeHashes(batch, { rpcUrl: process.env.RPC_URL, nonce: batch.hashes.nonce });
    const bad = diffHashes(batch.hashes, cur);
    printHashes(cur);
    if (bad.length) { console.error(`CHECK FAILED, differing: ${bad.join(", ")}`); process.exit(1); }
    const onChain = BigInt(await (await Safe.init({ provider: process.env.RPC_URL, safeAddress: cur.safeAddress })).getNonce());
    if (BigInt(batch.hashes.nonce) < onChain) { console.error(`CHECK FAILED: recorded nonce ${batch.hashes.nonce} < on-chain nonce ${onChain} (nonce already used)`); process.exit(1); }
    if (BigInt(batch.hashes.nonce) > onChain) console.warn(`WARN: recorded nonce ${batch.hashes.nonce} > on-chain nonce ${onChain}; not yet reachable (earlier Safe txs must execute first)`);
    console.log("CHECK PASS");
} else {
    const h = await computeHashes(batch, { rpcUrl: process.env.RPC_URL, nonce: a.nonce === undefined ? undefined : BigInt(a.nonce) });
    printHashes(h);
    if (a.write) {
        writeFileSync(path, JSON.stringify({ ...batch, hashes: h }, null, 2) + "\n");
        console.log(`recorded in ${path}`);
    }
}
