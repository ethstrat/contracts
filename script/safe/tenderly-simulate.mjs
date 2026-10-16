#!/usr/bin/env node
// Simulate a batch's Safe execTransaction on Tenderly (private sim) with approved-hash storage overrides.
// Usage: node --env-file=.env script/safe/tenderly-simulate.mjs <batch.json> [--nonce N] [--from 0xOwner] [--print-only]
// Env: RPC_URL (+ TENDERLY_ACCESS_KEY, TENDERLY_ACCOUNT, TENDERLY_PROJECT unless --print-only)
// Signatures are faked: approvedHashes[owner][safeTxHash]=1 set via state_objects for `threshold` owners.
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { Contract, Interface, JsonRpcProvider, getAddress, toBeHex, keccak256, solidityPacked, zeroPadValue, AbiCoder } from "ethers";
import { computeHashes } from "./lib/safe-hash.mjs";

// Safe v1.3/1.4.1 layout: slot 8 = mapping(address => mapping(bytes32 => uint256)) approvedHashes (verified on anvil fork).
const APPROVED_HASHES_SLOT = 8;
const approvedSlot = (owner, hash) =>
    keccak256(solidityPacked(["bytes32", "bytes32"], [hash, keccak256(AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [owner, APPROVED_HASHES_SLOT]))]));
const ONE = zeroPadValue("0x01", 32);

const SAFE_ABI = [
    "function getOwners() view returns (address[])",
    "function getThreshold() view returns (uint256)",
    "function nonce() view returns (uint256)",
    "function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) payable returns (bool)",
    "event ExecutionSuccess(bytes32 txHash, uint256 payment)",
    "event ExecutionFailure(bytes32 txHash, uint256 payment)",
];

// Returns {from, to, input, state_objects, safeTxHash, hashes}. Exported shape reused by the fork check.
export async function buildSimulation(batch, { rpcUrl, nonce, from }) {
    const h = await computeHashes(batch, { rpcUrl, nonce, withTx: true });
    const safe = new Contract(h.safeAddress, SAFE_ABI, new JsonRpcProvider(rpcUrl));
    const owners = [...(await safe.getOwners())].sort((x, y) => (BigInt(x) < BigInt(y) ? -1 : 1));
    const threshold = Number(await safe.getThreshold());
    // Pick threshold signers ascending by address (Safe requires ordered sigs); a requested --from goes in first.
    const signers = (from ? [getAddress(from), ...owners.filter((o) => o !== getAddress(from))] : owners).slice(0, threshold);
    if (from && !owners.includes(getAddress(from))) throw new Error(`--from ${from} is not an owner of ${h.safeAddress}`);
    signers.sort((x, y) => (BigInt(x) < BigInt(y) ? -1 : 1));
    const sender = from ? getAddress(from) : signers[0];
    const signatures = "0x" + signers.map((o) => zeroPadValue(o, 32).slice(2) + "00".repeat(32) + "01").join("");
    const d = h.txData;
    const input = new Interface(SAFE_ABI).encodeFunctionData("execTransaction", [d.to, d.value, d.data, d.operation, d.safeTxGas, d.baseGas, d.gasPrice, d.gasToken, d.refundReceiver, signatures]);
    const storage = Object.fromEntries(signers.map((o) => [approvedSlot(o, h.safeTxHash), ONE]));
    // A non-current --nonce needs the Safe's own nonce (slot 5, v1.3/1.4.1) overridden, else the Safe hashes at the on-chain nonce (GS025).
    if (BigInt(h.nonce) !== (await safe.nonce())) storage[zeroPadValue("0x05", 32)] = zeroPadValue(toBeHex(h.nonce), 32);
    // Optional batch.stateOverrides ({address: {storage: {slot: value}}}), e.g. pre-funding balances; not part of the hashes.
    const state_objects = { ...(batch.stateOverrides ?? {}), [h.safeAddress]: { storage } };
    return { from: sender, to: h.safeAddress, input, state_objects, signers, threshold, hashes: h };
}

if (import.meta.url === `file://${process.argv[1]}`) {
    const { values: a, positionals: [path] } = parseArgs({
        allowPositionals: true,
        options: { nonce: { type: "string" }, from: { type: "string" }, "print-only": { type: "boolean" } },
    });
    if (!path) throw new Error("usage: tenderly-simulate.mjs <batch.json> [--nonce N] [--from 0xOwner] [--print-only]");
    const need = ["RPC_URL", ...(a["print-only"] ? [] : ["TENDERLY_ACCESS_KEY", "TENDERLY_ACCOUNT", "TENDERLY_PROJECT"])].filter((k) => !process.env[k]);
    if (need.length) throw new Error(`missing env var(s): ${need.join(", ")} (set in .env)`);
    const batch = JSON.parse(readFileSync(path, "utf8"));
    const s = await buildSimulation(batch, { rpcUrl: process.env.RPC_URL, nonce: a.nonce === undefined ? undefined : BigInt(a.nonce), from: a.from });
    const body = {
        network_id: "1", from: s.from, to: s.to, input: s.input, value: "0", save: true, save_if_fails: true,
        simulation_type: "full", state_objects: s.state_objects, // no block_number => latest
    };
    console.log(`Safe:        ${s.to} (nonce ${s.hashes.nonce}, threshold ${s.threshold}, signers ${s.signers.join(",")})`);
    console.log(`safeTxHash:  ${s.hashes.safeTxHash}`);
    if (a["print-only"]) {
        console.log("\n--- request body ---\n" + JSON.stringify(body, null, 2));
        console.log("\n--- Tenderly UI simulator (Contract: custom/raw input) ---");
        console.log(`From:        ${s.from}\nTo:          ${s.to}\nInput data:  ${s.input}\nState overrides (contract ${s.to}):`);
        for (const [k, v] of Object.entries(s.state_objects[s.to].storage)) console.log(`  slot ${k} = ${v}`);
        process.exit(0);
    }
    const { TENDERLY_ACCESS_KEY: key, TENDERLY_ACCOUNT: acct, TENDERLY_PROJECT: proj } = process.env;
    let res, json;
    try {
        res = await fetch(`https://api.tenderly.co/api/v1/account/${acct}/project/${proj}/simulate`, {
            method: "POST", headers: { "Content-Type": "application/json", "X-Access-Key": key }, body: JSON.stringify(body),
        });
        json = await res.json();
    } catch (e) { console.error(`Tenderly request failed: ${e.message}`); process.exit(1); }
    if (!res.ok) { console.error(`Tenderly API ${res.status}: ${JSON.stringify(json?.error ?? json)}`); process.exit(1); }
    const tx = json.transaction, sim = json.simulation;
    console.log(`Simulation:  https://dashboard.tenderly.co/${acct}/${proj}/simulator/${sim?.id}`);
    console.log(`Status:      ${tx?.status ? "success" : "REVERT"}${tx?.error_message ? ` (${tx.error_message})` : ""}`);
    console.log(`Gas used:    ${tx?.gas_used}`);
    const logs = tx?.transaction_info?.logs ?? [];
    const ev = logs.filter((l) => /^Execution(Success|Failure)$/.test(l.name ?? "")).map((l) => l.name);
    console.log(`Safe events: ${ev.length ? ev.join(", ") : "none decoded (ExecutionSuccess/Failure not found)"}`);
    if (!tx?.status) process.exit(2);
}
