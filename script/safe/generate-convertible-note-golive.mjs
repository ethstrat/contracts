#!/usr/bin/env node
// Generate the convertible-note go-live Safe batch (plain schema + tx-builder export).
// Usage: node --env-file=.env script/safe/generate-convertible-note-golive.mjs \
//   --note <noteAddr> --desEth <desEthAddr> --steth-receiver <addr> --cdt-recipient <addr> \
//   [--max-debt <currentMaxDebtWei>] [--no-grant-minter-desEth] [--no-grant-minter-cdt] [--no-untrip]
// Untrips (esETH, CDT, note), desETH + CDT minter grants are ON by default; --no-* opts out.
// Current maxDebt is read from RPC_URL unless --max-debt is given (offline).
import { readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
import { Interface, JsonRpcProvider, Contract, getAddress, parseUnits, MaxUint256, ZeroAddress } from "ethers";

const { values: a } = (await import("node:util")).parseArgs({
    options: {
        note: { type: "string" },
        desEth: { type: "string" },
        "steth-receiver": { type: "string" },
        "cdt-recipient": { type: "string" },
        "max-debt": { type: "string" },
        "no-grant-minter-desEth": { type: "boolean" },
        "no-grant-minter-cdt": { type: "boolean" },
        "no-untrip": { type: "boolean" },
    },
});
for (const k of ["note", "desEth", "steth-receiver", "cdt-recipient"]) {
    if (!a[k]) throw new Error(`missing --${k}`);
}
const dep = JSON.parse(readFileSync("script/deployments/1/config/deploymentAddresses.json", "utf8"));
const ext = JSON.parse(readFileSync("script/deployments/1/config/externalAddresses.json", "utf8"));
const { multisigs, tripwire } = JSON.parse(readFileSync("script/deployments/1/config/internalAddresses.json", "utf8")).protocol;
const SAFE = multisigs.main;
const TREASURY_MANAGER = multisigs.unencumbered; // esETH.treasuryManager(); only it holds esETH and may redeem
const [note, desEth, receiver, cdtTo] = [a.note, a.desEth, a["steth-receiver"], a["cdt-recipient"]].map(getAddress);
const { esETH, cdt } = dep;
console.warn(`!!! ASSUMPTION: stETH receiver = ${receiver}, CDT recipient = ${cdtTo} (proposing Safe = ${SAFE}) -- confirm before proposing`);
const stETH = ext.lido.stETH;

const E18 = 10n ** 18n;
const DES_ETH_AMOUNT = 1623n * E18;
const STETH_OUT = 1900n * E18; // esETH holds 2000 stETH; 100 stay for conversions
const BCF = (25n * E18) / 100n; // 0.25 * SCALE (SCALE = 1e18 in EthStrategyConvertibleNote)
const CDT_AMOUNT = parseUnits("483143.48", 18); // CDT is OZ ERC20, 18 decimals
const ERC20_TYPE = 1; // esETH.TokenType.ERC20 (1:1)

let maxDebt;
if (a["max-debt"]) maxDebt = BigInt(a["max-debt"]);
else {
    if (!process.env.RPC_URL) throw new Error("set RPC_URL (node --env-file=.env) or pass --max-debt");
    maxDebt = await new Contract(note, ["function maxDebt() view returns (uint256)"], new JsonRpcProvider(process.env.RPC_URL)).maxDebt();
}
if (maxDebt === MaxUint256) throw new Error("maxDebt is uint256.max (cap disabled); nothing to raise");

const tx = (label, to, contractName, signature, args) => ({ label, to, contractName, signature, args: args.map((x) => (typeof x === "bigint" ? x.toString() : x)) });
const transactions = [];
// Globally tripped on mainnet and needed for go-live; SAFE is the TripwireController guardian. Others (old note, ESPN deposit token) are not ours/not needed.
if (!a["no-untrip"]) for (const [n, t] of [["esETH", esETH], ["CDT", cdt], ["note", note]]) transactions.push(tx(`Untrip ${n}`, tripwire.controller, "TripwireController", "resetGlobal(address)", [t]));
if (!a["no-grant-minter-desEth"]) transactions.push(tx("Grant Safe desETH minter", desEth, "DesEthToken", "manageMinter(address,bool)", [SAFE, true]));
if (!a["no-grant-minter-cdt"]) transactions.push(tx("Grant Safe CDT minter", cdt, "CdtToken", "manageMinter(address,bool)", [SAFE, true]));
// TM-executed calls: SAFE is TM's owner, approved-hash style signature (v=1, r=SAFE)
const ownerSig = "0x" + SAFE.slice(2).toLowerCase().padStart(64, "0") + "0".repeat(64) + "01";
const viaTM = (label, to, iface, fn, args) => tx(label, TREASURY_MANAGER, "Safe", "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)", [to, 0n, new Interface([`function ${iface}`]).encodeFunctionData(fn, args), 0, 0n, 0n, 0n, ZeroAddress, ZeroAddress, ownerSig]);
const redeemData = new Interface(["function redeem(address,uint256,address)"]).encodeFunctionData("redeem", [stETH, STETH_OUT, receiver]);
// TM is isMinter on esETH and bypasses isMintable, so the desETH config stays not user-mintable (re-asserted idempotently).
console.warn(`!!! ASSUMPTION: esETH minted from desETH goes to ${TREASURY_MANAGER} (treasuryManager Safe)`);
transactions.push(
    tx("Mint 1623 desETH to treasuryManager Safe", desEth, "DesEthToken", "mint(address,uint256)", [TREASURY_MANAGER, DES_ETH_AMOUNT]),
    tx("Register desETH in esETH (ERC20 1:1, not mintable/redeemable by users)", esETH, "esETH", "setTokenConfig(address,uint8,bool,bool)", [desEth, ERC20_TYPE, false, false]),
    viaTM("Approve esETH to pull 1623 desETH from treasuryManager Safe", desEth, "approve(address,uint256)", "approve", [esETH, DES_ETH_AMOUNT]),
    viaTM("Mint esETH from 1623 desETH via treasuryManager Safe", esETH, "mint(address,uint256,address)", "mint", [desEth, DES_ETH_AMOUNT, TREASURY_MANAGER]),
    viaTM("Withdraw 1900 stETH from esETH via treasuryManager Safe (burns its esETH)", esETH, "redeem(address,uint256,address)", "redeem", [stETH, STETH_OUT, receiver]),
    tx("Set BCF to 0.25", note, "EthStrategyConvertibleNote", "setBCF(uint256)", [BCF]),
    tx("Raise CDT debt cap by 483,143.48", note, "EthStrategyConvertibleNote", "setMaxDebt(uint256)", [maxDebt + CDT_AMOUNT]),
    tx("Mint 483,143.48 CDT", cdt, "CdtToken", "mint(address,uint256)", [cdtTo, CDT_AMOUNT]),
);

// self-check: calldata round-trips through decode/encode
for (const t of transactions) {
    const i = new Interface([`function ${t.signature}`]);
    const name = t.signature.split("(")[0];
    const data = i.encodeFunctionData(name, t.args);
    assert.equal(i.encodeFunctionData(name, i.decodeFunctionData(name, data)), data);
}
const amt = (n) => transactions.find((t) => t.label.includes(n)).args;
assert.equal(amt("Mint 1623 desETH")[1], "1623000000000000000000");
assert.equal(amt("Withdraw")[2], redeemData);
assert.equal(amt("Mint 1623 desETH")[0], TREASURY_MANAGER);
const inner = (n) => new Interface(["function mint(address,uint256,address)", "function approve(address,uint256)"]).parseTransaction({ data: amt(n)[2] });
assert.deepEqual([...inner("Mint esETH").args], [desEth, DES_ETH_AMOUNT, TREASURY_MANAGER]);
assert.deepEqual([...inner("Approve esETH").args], [esETH, DES_ETH_AMOUNT]);
const idx = (n) => transactions.findIndex((t) => t.label.includes(n));
assert(idx("Approve") < idx("Mint esETH") && idx("Mint esETH") < idx("Withdraw"));
assert.equal(amt("BCF")[0], "250000000000000000");
assert.equal(amt("Mint 483")[1], "483143480000000000000000");
assert.equal(BigInt(amt("Raise")[0]) - maxDebt, CDT_AMOUNT);

const out = "script/safe/batches/convertible-note-golive.json";
writeFileSync(out, JSON.stringify({
    description: "Convertible note go-live: mint esETH from desETH via the treasuryManager Safe, withdraw 1900 stETH, set BCF 0.25, raise CDT debt cap and mint CDT.",
    safeAddress: SAFE, chainId: 1, transactions,
}, null, 2) + "\n");
console.log(out, `(maxDebt ${maxDebt} -> ${maxDebt + CDT_AMOUNT})`);
spawnSync("node", ["script/safe/export-tx-builder.mjs", out], { stdio: "inherit" });
if (process.env.RPC_URL) spawnSync("node", ["script/safe/hash-batch.mjs", out, "--write"], { stdio: "inherit" }); // fresh hashes at current nonce
