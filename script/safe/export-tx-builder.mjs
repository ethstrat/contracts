#!/usr/bin/env node
// Convert a propose-batch.mjs batch JSON file into a Safe{Wallet} Transaction Builder-compatible
// JSON file, importable via drag-and-drop in the Transaction Builder app.
// Usage: node script/safe/export-tx-builder.mjs <path-to-batch.json>
//
// See script/safe/propose-batch.mjs for the source batch schema.

import { readFileSync, writeFileSync } from "node:fs";
import { FunctionFragment } from "ethers";

function fail(message) {
    console.error(`Error: ${message}`);
    process.exit(1);
}

const batchPath = process.argv[2];
if (!batchPath) {
    fail("missing batch JSON path.\nUsage: node script/safe/export-tx-builder.mjs <path-to-batch.json>");
}

let batch;
try {
    batch = JSON.parse(readFileSync(batchPath, "utf8"));
} catch (err) {
    fail(`could not read/parse batch file "${batchPath}": ${err.message}`);
}

if (!batch.safeAddress) fail('batch config missing "safeAddress"');
if (!batch.chainId) fail('batch config missing "chainId"');
if (!Array.isArray(batch.transactions) || batch.transactions.length === 0) {
    fail('batch config missing a non-empty "transactions" array');
}

// Transaction Builder expects every contractInputsValues entry as a string, arrays included
// (comma-joined, matching what the Transaction Builder UI itself produces for array inputs).
function stringifyArg(value) {
    if (Array.isArray(value)) return value.map(stringifyArg).join(",");
    return String(value);
}

const transactions = batch.transactions.map((tx, i) => {
    let fragment;
    try {
        fragment = FunctionFragment.from(`function ${tx.signature}`);
    } catch (err) {
        fail(`failed to parse transactions[${i}] signature "${tx.signature}": ${err.message}`);
    }
    const inputs = fragment.inputs.map((input, argIndex) => ({
        internalType: input.type,
        name: `arg${argIndex}`,
        type: input.type,
    }));
    const contractInputsValues = Object.fromEntries(
        inputs.map((input, argIndex) => [input.name, stringifyArg(tx.args[argIndex])]),
    );
    return {
        to: tx.to,
        value: "0",
        data: null,
        contractMethod: { inputs, name: fragment.name, payable: false },
        contractInputsValues,
    };
});

const output = {
    version: "1.0",
    chainId: String(batch.chainId),
    createdAt: Date.now(),
    meta: {
        name: batch.description ?? batchPath,
        description: batch.description ?? "",
        txBuilderVersion: "1.18.0",
        createdFromSafeAddress: batch.safeAddress,
        createdFromOwnerAddress: "",
        // Omitted rather than guessed: Safe's Transaction Builder checksum is a specific
        // keccak-based algorithm not vendored in this repo's @safe-global packages (checked
        // node_modules/@safe-global — no match). A wrong checksum reads as "tampered"; an
        // absent one just reads as "unable to verify" and still imports fine.
        checksum: null,
    },
    transactions,
};

const outPath = batchPath.replace(/\.json$/, ".tx-builder.json");
writeFileSync(outPath, JSON.stringify(output, null, 2) + "\n");
console.log(outPath);
