#!/usr/bin/env node
// Propose a batch of Safe multisig transactions from a plain, reviewable JSON config.
// Usage: node script/safe/propose-batch.mjs <path-to-batch.json>
//
// Required env vars:
//   RPC_URL                    - mainnet (or target chain) RPC endpoint
//   SAFE_API_KEY               - Safe Transaction Service API key (https://developer.safe.global)
//   Signer (exactly one of):
//     SAFE_PROPOSER_PRIVATE_KEY               - raw private key of a Safe owner/delegate
//     SAFE_PROPOSER_KEYSTORE_PATH + _ADDRESS  - path to a Foundry/V3 keystore JSON (e.g. from
//                                                `cast wallet import`) and the address it
//                                                corresponds to. The password is never read by
//                                                this script or stored anywhere: `cast wallet
//                                                sign` prompts for it interactively at the
//                                                terminal.
//
// See script/safe/batches/*.json for the config schema.

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { Interface, getAddress, verifyTypedData } from "ethers";
import Safe, { EthSafeSignature, adjustVInSignature, generateTypedData } from "@safe-global/protocol-kit";
import SafeApiKit from "@safe-global/api-kit";

function fail(message) {
    console.error(`Error: ${message}`);
    process.exit(1);
}

const batchPath = process.argv[2];
if (!batchPath) {
    fail("missing batch JSON path.\nUsage: node script/safe/propose-batch.mjs <path-to-batch.json>");
}

const RPC_URL = process.env.RPC_URL;
const SAFE_PROPOSER_PRIVATE_KEY = process.env.SAFE_PROPOSER_PRIVATE_KEY;
const SAFE_PROPOSER_KEYSTORE_PATH = process.env.SAFE_PROPOSER_KEYSTORE_PATH;
const SAFE_PROPOSER_ADDRESS = process.env.SAFE_PROPOSER_ADDRESS;
const SAFE_API_KEY = process.env.SAFE_API_KEY;

if (!RPC_URL) fail("RPC_URL env var is required");
if (!SAFE_API_KEY) fail("SAFE_API_KEY env var is required (get one at https://developer.safe.global)");

const hasPrivateKey = !!SAFE_PROPOSER_PRIVATE_KEY;
const hasKeystore = !!SAFE_PROPOSER_KEYSTORE_PATH || !!SAFE_PROPOSER_ADDRESS;
if (hasPrivateKey && hasKeystore) {
    fail(
        "both SAFE_PROPOSER_PRIVATE_KEY and SAFE_PROPOSER_KEYSTORE_PATH/_ADDRESS are set — use exactly one signer method",
    );
}
if (!hasPrivateKey && !hasKeystore) {
    fail(
        "no signer configured — set either SAFE_PROPOSER_PRIVATE_KEY, or both SAFE_PROPOSER_KEYSTORE_PATH and SAFE_PROPOSER_ADDRESS",
    );
}
if (hasKeystore && !SAFE_PROPOSER_KEYSTORE_PATH) fail("SAFE_PROPOSER_KEYSTORE_PATH env var is required");
if (hasKeystore && !SAFE_PROPOSER_ADDRESS) {
    fail(
        "SAFE_PROPOSER_ADDRESS env var is required — the address the keystore corresponds to (Foundry keystores don't store it in plaintext, so it can't be derived without decrypting)",
    );
}
let signerAddress = SAFE_PROPOSER_ADDRESS;
if (hasKeystore) {
    try {
        signerAddress = getAddress(SAFE_PROPOSER_ADDRESS);
    } catch {
        fail(`SAFE_PROPOSER_ADDRESS is not a valid address: "${SAFE_PROPOSER_ADDRESS}"`);
    }
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

// The one safety check that actually matters: no unfilled placeholders like "<FOO>" reach a
// real Safe proposal.
const PLACEHOLDER_RE = /^<.*>$/;
function checkPlaceholders(value, path) {
    if (typeof value === "string" && PLACEHOLDER_RE.test(value)) {
        fail(`placeholder value still present at ${path}: "${value}" — fill in the real value before proposing`);
    }
    if (Array.isArray(value)) value.forEach((v, i) => checkPlaceholders(v, `${path}[${i}]`));
}

batch.transactions.forEach((tx, i) => {
    for (const field of ["to", "contractName", "signature", "args"]) {
        if (tx[field] === undefined) fail(`transactions[${i}] missing "${field}"`);
    }
    checkPlaceholders(tx.to, `transactions[${i}].to`);
    checkPlaceholders(tx.args, `transactions[${i}].args`);
});

const metaTransactions = batch.transactions.map((tx) => {
    const fnName = tx.signature.split("(")[0];
    let data;
    try {
        data = new Interface([`function ${tx.signature}`]).encodeFunctionData(fnName, tx.args);
    } catch (err) {
        fail(`failed to encode transactions[${batch.transactions.indexOf(tx)}] (${tx.signature}): ${err.message}`);
    }
    return { to: tx.to, value: "0", data };
});

console.log(`Batch: ${batch.description ?? "(no description)"}`);
console.log(`Safe:  ${batch.safeAddress} (chainId ${batch.chainId})`);
console.log(`${batch.transactions.length} transaction(s):\n`);
batch.transactions.forEach((tx, i) => {
    const fnName = tx.signature.split("(")[0];
    console.log(`  [${i}] ${tx.label ?? fnName}`);
    console.log(`      contract: ${tx.contractName} (${tx.to})`);
    console.log(`      call:     ${fnName}(${tx.args.map((a) => JSON.stringify(a)).join(", ")})`);
});
console.log("");

// eth: prefix used by Safe{Wallet}'s URL scheme for the chains we actually use here.
// ponytail: small fixed lookup, add entries if/when other chains come into play.
const SAFE_WALLET_CHAIN_PREFIX = { 1: "eth", 11155111: "sep", 8453: "base", 42161: "arb1", 10: "oeth" };

// Signs the Safe transaction via `cast wallet sign`, which owns the whole keystore
// password prompt/decrypt step — the password never enters this process. stdin/stderr are
// inherited so the interactive masked-input prompt reaches the user's real terminal; only
// stdout (the signature) is captured.
//
// Uses protocol-kit's own `generateTypedData` (src/utils/eip-712/index.ts) rather than
// hand-rolling the EIP-712 domain/types — it's the exact same construction getTransactionHash()
// uses internally, so this can't drift from what the SDK considers the real Safe tx hash.
async function signWithKeystore(protocolKit, safeTransaction) {
    const safeVersion = protocolKit.getContractVersion();
    const chainId = Number(await protocolKit.getChainId());
    const typedData = generateTypedData({
        safeAddress: batch.safeAddress,
        safeVersion,
        chainId,
        data: safeTransaction.data,
    });
    // ethers rejects a `types` map that includes "EIP712Domain" (it derives that itself from
    // `domain`), so strip it before handing typedData to cast/ethers.
    const { EIP712Domain: _domainType, ...signingTypes } = typedData.types;

    const result = spawnSync(
        "cast",
        ["wallet", "sign", JSON.stringify(typedData), "--data", "--keystore", SAFE_PROPOSER_KEYSTORE_PATH],
        { stdio: ["inherit", "pipe", "inherit"], encoding: "utf8" },
    );
    if (result.error) fail(`failed to run "cast wallet sign": ${result.error.message}`);
    if (result.status !== 0) fail(`"cast wallet sign" exited with code ${result.status}`);

    let signature = result.stdout.trim();
    signature = await adjustVInSignature("eth_signTypedData", signature);

    // The one safety check that actually matters: confirm the signature we got back actually
    // recovers to the keystore address we were told to expect, before this can ever reach
    // api-kit. Catches any subtle mismatch in the EIP-712 construction (wrong domain, wrong
    // field order, wrong types) before it produces a bad or silently-invalid proposal.
    const recovered = verifyTypedData(typedData.domain, signingTypes, typedData.message, signature);
    if (recovered.toLowerCase() !== signerAddress.toLowerCase()) {
        fail(
            `signature verification failed: recovered signer ${recovered} does not match SAFE_PROPOSER_ADDRESS ${signerAddress} — refusing to propose`,
        );
    }

    return new EthSafeSignature(signerAddress, signature);
}

try {
    const protocolKit = await Safe.init({
        provider: RPC_URL,
        signer: hasPrivateKey ? SAFE_PROPOSER_PRIVATE_KEY : undefined,
        safeAddress: batch.safeAddress,
    });

    const safeTransaction = await protocolKit.createTransaction({ transactions: metaTransactions });
    const safeTxHash = await protocolKit.getTransactionHash(safeTransaction);

    let signedSafeTransaction;
    let senderAddress;
    if (hasPrivateKey) {
        signedSafeTransaction = await protocolKit.signTransaction(safeTransaction);
        senderAddress = await protocolKit.getSafeProvider().getSignerAddress();
    } else {
        const signature = await signWithKeystore(protocolKit, safeTransaction);
        safeTransaction.addSignature(signature);
        signedSafeTransaction = safeTransaction;
        senderAddress = signerAddress;
    }
    const senderSignature = signedSafeTransaction.getSignature(senderAddress)?.data;
    if (!senderSignature) fail("failed to produce a signature for the proposer address");

    const apiKit = new SafeApiKit({ chainId: BigInt(batch.chainId), apiKey: SAFE_API_KEY });
    await apiKit.proposeTransaction({
        safeAddress: batch.safeAddress,
        safeTransactionData: signedSafeTransaction.data,
        safeTxHash,
        senderAddress,
        senderSignature,
    });

    const prefix = SAFE_WALLET_CHAIN_PREFIX[batch.chainId] ?? batch.chainId;
    console.log(`Proposed. Safe transaction hash: ${safeTxHash}`);
    console.log(`Review at: https://app.safe.global/transactions/tx?safe=${prefix}:${batch.safeAddress}&id=${safeTxHash}`);
} catch (err) {
    fail(`Safe SDK error: ${err.message ?? err}`);
}
