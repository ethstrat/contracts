#!/usr/bin/env node
// Generate a Safe batch calling TripwireController.addOperator(guarded, operator) from the main Safe (guardian).
// Usage: node --env-file=.env script/safe/generate-add-operator.mjs <operatorAddress> [--contracts esETH,cdt,note] [--out path] [--dry-run]
// Contract names: esETH, cdt, note, desETH. Skips contracts where operator is already set; errors if the Safe is not the guardian.
// Writes the batch + hashes (as hash-batch.mjs --write) + .tx-builder.json (via export-tx-builder.mjs).
import { readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
import { parseArgs } from "node:util";
import { Interface, JsonRpcProvider, Contract, getAddress, ZeroAddress } from "ethers";
import { computeHashes, printHashes } from "./lib/safe-hash.mjs";

const { values: a, positionals: [opArg] } = parseArgs({
    allowPositionals: true,
    options: { contracts: { type: "string", default: "esETH,cdt,note" }, out: { type: "string" }, "dry-run": { type: "boolean" } },
});
if (!opArg) throw new Error("usage: generate-add-operator.mjs <operatorAddress> [--contracts esETH,cdt,note] [--out path] [--dry-run]");
if (!process.env.RPC_URL) throw new Error("set RPC_URL (node --env-file=.env)");
const operator = getAddress(opArg);
assert.notEqual(operator, ZeroAddress, "operator is the zero address");

const dep = JSON.parse(readFileSync("script/deployments/1/config/deploymentAddresses.json", "utf8"));
const { multisigs, tripwire } = JSON.parse(readFileSync("script/deployments/1/config/internalAddresses.json", "utf8")).protocol;
const SAFE = multisigs.main;
const CONTROLLER = tripwire.controller;
const KNOWN = { esETH: dep.esETH, cdt: dep.cdt, note: dep["convertible-note"], desETH: dep.desETH };

const names = a.contracts.split(",").map((s) => s.trim());
for (const n of names) if (!KNOWN[n]) throw new Error(`unknown contract "${n}" (known: ${Object.keys(KNOWN).join(", ")})`);

const sig = "addOperator(address,address)";
const ctl = new Contract(
    CONTROLLER,
    ["function guardian(address) view returns (address)", "function isOperator(address,address) view returns (bool)"],
    new JsonRpcProvider(process.env.RPC_URL),
);
const transactions = [];
for (const n of names) {
    const target = getAddress(KNOWN[n]);
    const g = await ctl.guardian(target);
    if (g !== SAFE) throw new Error(`guardian(${n}) = ${g}, expected main Safe ${SAFE}`);
    if (await ctl.isOperator(target, operator)) {
        console.warn(`WARN: ${operator} is already an operator on ${n}; skipping`);
        continue;
    }
    transactions.push({ label: `Add ${operator} as TripwireController operator on ${n}`, to: CONTROLLER, contractName: "TripwireController", signature: sig, args: [target, operator] });
}
if (!transactions.length) throw new Error("nothing to add: operator already set on all requested contracts");

const batch = {
    description: `Add ${operator} as TripwireController operator on ${transactions.length} contract(s): ${names.join(", ")}.`,
    safeAddress: SAFE,
    chainId: 1,
    transactions,
};
// self-check: calldata round-trips to the intended args
const iface = new Interface([`function ${sig}`]);
for (const t of transactions) assert.deepEqual([...iface.decodeFunctionData("addOperator", iface.encodeFunctionData("addOperator", t.args))], t.args);

batch.hashes = await computeHashes(batch, { rpcUrl: process.env.RPC_URL });
if (a["dry-run"]) {
    console.log(JSON.stringify(batch, null, 2));
    process.exit(0);
}
const out = a.out ?? `script/safe/batches/add-tripwire-operator-${operator.slice(2, 10)}.json`;
writeFileSync(out, JSON.stringify(batch, null, 2) + "\n");
console.log(`wrote ${out}`);
printHashes(batch.hashes);
const r = spawnSync("node", ["script/safe/export-tx-builder.mjs", out], { stdio: "inherit" });
if (r.status) process.exit(r.status);
