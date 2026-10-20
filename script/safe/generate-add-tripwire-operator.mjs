#!/usr/bin/env node
// Main-Safe batch: adds operators to every guardian-controlled TripwireController target (skips targets where already operator).
// Usage: yarn safe:add-operator (operators are the CONFIG constant below)
// then makes WETH redeemable on esETH (type/isMintable preserved). Nonce = on-chain nonce at run time. Writes batches/add-tripwire-operator.json (+ .tx-builder.json).
import { readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { JsonRpcProvider, Contract, ZeroAddress } from "ethers";
import { computeHashes, printHashes } from "./lib/safe-hash.mjs";

// ---- CONFIG ----
const operators = [
    "0x27F60886045Eb16a2464E055d48508F46D93e306", // new operator requested by the team
    "0xEfa9f0766638Fc2258e13A0Ce1b9dA522412D6dF", // existing emergency operator (multisigs.tripwire-operator1)
];

if (!process.env.RPC_URL) throw new Error("set RPC_URL (node --env-file=.env)");

const dep = JSON.parse(readFileSync("script/deployments/1/config/deploymentAddresses.json", "utf8"));
const { multisigs, tripwire } = JSON.parse(readFileSync("script/deployments/1/config/internalAddresses.json", "utf8")).protocol;
const SAFE = multisigs.main;
const ctl = new Contract(tripwire.controller, ["function guardian(address) view returns (address)", "function isOperator(address,address) view returns (bool)"], new JsonRpcProvider(process.env.RPC_URL));

const transactions = [];
// Every address in deploymentAddresses.json with guardian == main Safe; guardian 0 = not tripwire-enabled (skipped).
for (const [name, target] of Object.entries(dep).filter(([, v]) => /^0x[0-9a-fA-F]{40}$/.test(v))) {
    const g = await ctl.guardian(target);
    if (g === ZeroAddress) { console.warn(`skip ${name}: no tripwire guardian`); continue; }
    if (g !== SAFE) throw new Error(`guardian(${name}) = ${g}, expected main Safe ${SAFE}`);
    for (const operator of operators) {
        if (await ctl.isOperator(target, operator)) { console.warn(`WARN: ${operator} already operator on ${name}; skipping`); continue; }
        transactions.push({ label: `Add ${operator} as TripwireController operator on ${name}`, to: tripwire.controller, contractName: "TripwireController", signature: "addOperator(address,address)", args: [target, operator] });
    }
}
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const eseth = new Contract(dep.esETH, ["function tokenConfigs(address) view returns (uint8 tokenType, bool isMintable, bool isRedeemable, uint256 totalMinted)"], ctl.runner);
const wc = await eseth.tokenConfigs(WETH);
if (wc.tokenType === 0n) throw new Error("WETH unsupported on esETH");
if (wc.isRedeemable) console.warn("WARN: WETH already redeemable on esETH; skipping");
else transactions.push({ label: `Make WETH redeemable from esETH (type ${wc.tokenType}, isMintable stays ${wc.isMintable}, isRedeemable true)`, to: dep.esETH, contractName: "esETH", signature: "setTokenConfig(address,uint8,bool,bool)", args: [WETH, wc.tokenType.toString(), wc.isMintable, true] });
if (!transactions.length) throw new Error("nothing to add");

const out = "script/safe/batches/add-tripwire-operator.json";
const batch = { description: `Add ${operators.join(", ")} as TripwireController operator(s) where missing; make WETH redeemable on esETH if not already (${transactions.length} txs)`, safeAddress: SAFE, chainId: 1, transactions };
batch.hashes = await computeHashes(batch, { rpcUrl: process.env.RPC_URL });
writeFileSync(out, JSON.stringify(batch, null, 2) + "\n");
transactions.forEach((t, i) => console.log(`${i + 1}. ${t.label}`));
printHashes(batch.hashes);
const r = spawnSync("node", ["script/safe/export-tx-builder.mjs", out], { stdio: "inherit" });
if (r.status) process.exit(r.status);
