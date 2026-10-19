#!/usr/bin/env node
// Revoke every live stETH allowance held by the treasuryManager Safe (0xF89f), as ONE main-Safe tx at the current on-chain nonce.
// Spenders = all stETH Approval(owner=treasuryManager) spenders ever seen (log scan from block 16,000,000) plus KNOWN, kept only if allowance > 0 now.
// Usage: node --env-file=.env script/safe/generate-revoke-steth-approvals.mjs [--dry-run]
import { readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { parseArgs } from "node:util";
import assert from "node:assert/strict";
import { Interface, JsonRpcProvider, Contract, getAddress, id, zeroPadValue, ZeroAddress } from "ethers";
import { computeHashes, printHashes } from "./lib/safe-hash.mjs";

const STETH = "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84";
const KNOWN = [ // Lido WQ, wstETH, Permit2, v4 PositionManager, Seaport, esETH, note, CoW VaultRelayer
    "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1", "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0", "0x000000000022D473030F116dDEE9F6B43aC78BA3",
    "0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e", "0x0000000000000068F116a894984e2DB1123eB395", "0xC92E8bdf79f0507f65a392b0ab4667716BFE0110",
];
const { multisigs } = JSON.parse(readFileSync("script/deployments/1/config/internalAddresses.json", "utf8")).protocol;
const dep = JSON.parse(readFileSync("script/deployments/1/config/deploymentAddresses.json", "utf8"));
const SAFE = multisigs.main, TM = multisigs.unencumbered;
KNOWN.push(dep.esETH, dep["convertible-note"]);
if (!process.env.RPC_URL) throw new Error("set RPC_URL (node --env-file=.env)");
const { values: a } = parseArgs({ options: { "dry-run": { type: "boolean" } } });
const p = new JsonRpcProvider(process.env.RPC_URL);
const steth = new Contract(STETH, ["function allowance(address,address) view returns (uint256)"], p);

const latest = await p.getBlockNumber();
const spenders = new Set(KNOWN.map(getAddress));
for (let f = 16_000_000; f <= latest; f += 500_000) {
    const logs = await p.getLogs({ address: STETH, topics: [id("Approval(address,address,uint256)"), zeroPadValue(TM, 32)], fromBlock: f, toBlock: Math.min(f + 499_999, latest) });
    for (const l of logs) spenders.add(getAddress("0x" + l.topics[2].slice(26)));
}
const live = [];
for (const s of spenders) { const al = await steth.allowance(TM, s); if (al > 0n) live.push([s, al]); }
assert(live.length > 0, "no live stETH allowances to revoke");

const tx = (label, to, contractName, signature, args) => ({ label, to, contractName, signature, args });
const ownerSig = "0x" + SAFE.slice(2).toLowerCase().padStart(64, "0") + "0".repeat(64) + "01"; // approved-hash style: v=1, r=SAFE (msg.sender)
const transactions = live.map(([s, al]) => tx(
    `Revoke stETH allowance of ${s} from treasuryManager Safe (was ${al === 2n ** 256n - 1n ? "MAX" : al})`, TM, "Safe",
    "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
    [STETH, "0", new Interface(["function approve(address,uint256)"]).encodeFunctionData("approve", [s, 0n]), 0, "0", "0", "0", ZeroAddress, ZeroAddress, ownerSig],
));
const batch = {
    description: `Revoke live stETH allowances (${live.map(([s]) => s).join(", ")}) held by the treasuryManager Safe ${TM}, one nested execTransaction each from the main Safe (owner)`,
    safeAddress: SAFE, chainId: 1, transactions,
};
batch.hashes = await computeHashes(batch, { rpcUrl: process.env.RPC_URL }); // current on-chain nonce
transactions.forEach((t, i) => console.log(`${i + 1}. ${t.label}`));
if (a["dry-run"]) { console.log(JSON.stringify(batch, null, 2)); process.exit(0); }
const out = "script/safe/batches/revoke-steth-approvals.json";
writeFileSync(out, JSON.stringify(batch, null, 2) + "\n");
printHashes(batch.hashes);
const r = spawnSync("node", ["script/safe/export-tx-builder.mjs", out], { stdio: "inherit" });
if (r.status) process.exit(r.status);
