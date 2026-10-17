// Convertible note go-live, part 2 (Mon 19 Oct 2026 02:00 UTC) Safe batch, sent from the main Safe:
//   raise CDT debt cap, make stETH redeemable from esETH, raise esETH allowances to the note from the
//   encumbered and treasuryManager Safes, and add any missing TripwireController operators on esETH, CDT, note.
// Operators = multisigs.tripwire-operator1 and tripwire-operator2 in script/deployments/1/config/internalAddresses.json (deduped).
// To change the operator: edit tripwire-operator2 there, then re-run `yarn safe:golive-monday`.
// Library: imported by generate-golive-monday.mjs (the Monday batch); exports the tx list.
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { Interface, JsonRpcProvider, Contract, getAddress, ZeroAddress } from "ethers";

// ---- CONFIG ----
const MAX_DEBT = 11_000_000n * 10n ** 18n; // CDT debt cap
const ALLOWANCE = 100n * 10n ** 18n; // esETH allowance to the note, from each holdings Safe
const STETH = "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84";
const dep = JSON.parse(readFileSync("script/deployments/1/config/deploymentAddresses.json", "utf8"));
const { multisigs, tripwire } = JSON.parse(readFileSync("script/deployments/1/config/internalAddresses.json", "utf8")).protocol;
export const SAFE = multisigs.main; // proposer and TripwireController guardian
const [ENCUMBERED, TREASURY_MANAGER] = [multisigs.encumbered, multisigs.unencumbered];
const { esETH, cdt, "convertible-note": note } = dep;

if (!process.env.RPC_URL) throw new Error("set RPC_URL (node --env-file=.env)");
const operators = [...new Set([multisigs["tripwire-operator1"], multisigs["tripwire-operator2"]].map(getAddress))];
for (const o of operators) assert.notEqual(o, ZeroAddress, "operator is the zero address");

const tx = (label, to, contractName, signature, args) => ({ label, to, contractName, signature, args: args.map((x) => (typeof x === "bigint" ? x.toString() : x)) });
// Call executed by a Safe owned by SAFE: approved-hash style signature (v=1, r=SAFE)
const ownerSig = "0x" + SAFE.slice(2).toLowerCase().padStart(64, "0") + "0".repeat(64) + "01";
const approveVia = (safe, label) =>
    tx(label, safe, "Safe", "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)", [
        esETH, 0n, new Interface(["function approve(address,uint256)"]).encodeFunctionData("approve", [note, ALLOWANCE]), 0, 0n, 0n, 0n, ZeroAddress, ZeroAddress, ownerSig,
    ]);

// ---- TRANSACTIONS (in order) ----
export const transactions = [
    tx("Set CDT debt cap (maxDebt) to 11,000,000", note, "EthStrategyConvertibleNote", "setMaxDebt(uint256)", [MAX_DEBT]),
    tx("Make stETH redeemable from esETH (ERC20 type 1, isMintable stays false, isRedeemable true)", esETH, "esETH", "setTokenConfig(address,uint8,bool,bool)", [STETH, 1, false, true]),
    approveVia(ENCUMBERED, "Raise esETH allowance to note to 100 esETH from encumbered Safe"),
    approveVia(TREASURY_MANAGER, "Raise esETH allowance to note to 100 esETH from treasuryManager Safe"),
];
const ctl = new Contract(
    tripwire.controller,
    ["function guardian(address) view returns (address)", "function isOperator(address,address) view returns (bool)"],
    new JsonRpcProvider(process.env.RPC_URL),
);
export const added = [];
for (const [name, target] of [["esETH", esETH], ["cdt", cdt], ["note", note]]) {
    const g = await ctl.guardian(target);
    if (g !== SAFE) throw new Error(`guardian(${name}) = ${g}, expected main Safe ${SAFE}`);
    for (const operator of operators) {
        if (await ctl.isOperator(target, operator)) { console.warn(`WARN: ${operator} is already an operator on ${name}; skipping`); continue; }
        added.push(operator);
        transactions.push(tx(`Add ${operator} as TripwireController operator on ${name}`, tripwire.controller, "TripwireController", "addOperator(address,address)", [target, operator]));
    }
}

// ---- VALIDATION: calldata round-trips through decode/encode ----
for (const t of transactions) {
    const i = new Interface([`function ${t.signature}`]);
    const name = t.signature.split("(")[0];
    const data = i.encodeFunctionData(name, t.args);
    assert.equal(i.encodeFunctionData(name, i.decodeFunctionData(name, data)), data);
}
