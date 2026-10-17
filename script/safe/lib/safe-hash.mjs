// Shared Safe tx hashing for propose-batch / hash-batch / generators.
// Which hardware-wallet screen shows what (Ledger/Trezor blind-sign EIP-712; from docs knowledge,
// verify on-device): domainSeparatorHash and messageHash are the two hashes Ledger shows on the
// "Safe tx" blind-sign screens; safeTxHash is the id shown in the Safe UI (= keccak(0x1901 || domain || message)).
// The Safe UI also shows the decoded MultiSend. All hashes are over the exact tx propose-batch creates.
import { Interface, TypedDataEncoder, keccak256, solidityPacked } from "ethers";
import Safe from "@safe-global/protocol-kit";

// Normalizes both batch schemas (plain / tx-builder) to {safeAddress, chainId, metaTransactions}. Throws on bad input.
// Tx-builder tx with data:null: encode from contractMethod+contractInputsValues. Throws on anything unsupported (arrays/tuples).
function txBuilderData(tx, i) {
    if (typeof tx.data === "string" && /^0x([0-9a-fA-F]{2})*$/.test(tx.data)) return tx.data;
    const m = tx.contractMethod, v = tx.contractInputsValues;
    if (tx.data != null || !m?.name || !Array.isArray(m.inputs) || !v) throw new Error(`transactions[${i}]: data is not hex and no contractMethod/contractInputsValues`);
    const args = m.inputs.map((inp) => {
        if (/[\[(]/.test(inp.type) || v[inp.name] === undefined) throw new Error(`transactions[${i}]: unsupported/missing input ${inp.name} (${inp.type})`);
        if (inp.type !== "bool") return v[inp.name];
        if (v[inp.name] !== "true" && v[inp.name] !== "false") throw new Error(`transactions[${i}]: bad bool ${v[inp.name]}`);
        return v[inp.name] === "true";
    });
    return new Interface([`function ${m.name}(${m.inputs.map((x) => x.type).join(",")})`]).encodeFunctionData(m.name, args);
}

export function toMetaTransactions(batch) {
    const isTxBuilder = !batch.safeAddress;
    const safeAddress = isTxBuilder ? batch.meta?.createdFromSafeAddress : batch.safeAddress;
    const metaTransactions = batch.transactions.map((tx, i) =>
        isTxBuilder
            ? { to: tx.to, value: tx.value ?? "0", data: txBuilderData(tx, i) }
            : {
                  to: tx.to,
                  value: "0",
                  data: new Interface([`function ${tx.signature}`]).encodeFunctionData(tx.signature.split("(")[0], tx.args),
              },
    );
    return { safeAddress, chainId: Number(batch.chainId), metaTransactions };
}

const SAFE_TX_TYPES = {
    SafeTx: [
        { name: "to", type: "address" },
        { name: "value", type: "uint256" },
        { name: "data", type: "bytes" },
        { name: "operation", type: "uint8" },
        { name: "safeTxGas", type: "uint256" },
        { name: "baseGas", type: "uint256" },
        { name: "gasPrice", type: "uint256" },
        { name: "gasToken", type: "address" },
        { name: "refundReceiver", type: "address" },
        { name: "nonce", type: "uint256" },
    ],
};

// nonce undefined => current on-chain nonce. Asserts protocol-kit and manual EIP-712 agree.
export async function computeHashes(batch, { rpcUrl, nonce, withTx }) {
    const { safeAddress, chainId, metaTransactions } = toMetaTransactions(batch);
    const kit = await Safe.init({ provider: rpcUrl, safeAddress });
    const version = kit.getContractVersion();
    // shortcut: Safe < 1.3.0 has no chainId in the domain; upgrade if ever needed.
    if (!/^1\.[3-9]|^[2-9]/.test(version)) throw new Error(`unsupported Safe version ${version}`);
    const onChainChainId = Number(await kit.getChainId());
    if (onChainChainId !== chainId) throw new Error(`batch chainId ${chainId} != RPC chainId ${onChainChainId}`);
    const useNonce = nonce ?? (await kit.getNonce());
    const safeTx = await kit.createTransaction({ transactions: metaTransactions, options: { nonce: useNonce } });
    const d = safeTx.data;
    const sdkHash = await kit.getTransactionHash(safeTx);

    const domain = { chainId, verifyingContract: safeAddress };
    const message = {
        to: d.to, value: d.value, data: d.data, operation: d.operation, safeTxGas: d.safeTxGas, baseGas: d.baseGas,
        gasPrice: d.gasPrice, gasToken: d.gasToken, refundReceiver: d.refundReceiver, nonce: d.nonce,
    };
    for (const k of ["value", "safeTxGas", "baseGas", "gasPrice"]) {
        if (BigInt(d[k]) !== 0n) throw new Error(`unexpected non-zero ${k}`);
    }
    const domainSeparatorHash = TypedDataEncoder.hashDomain(domain);
    const messageHash = TypedDataEncoder.from(SAFE_TX_TYPES).hash(message);
    const safeTxHash = keccak256(solidityPacked(["bytes2", "bytes32", "bytes32"], ["0x1901", domainSeparatorHash, messageHash]));
    if (safeTxHash.toLowerCase() !== sdkHash.toLowerCase()) {
        throw new Error(`HASH CROSS-CHECK FAILED: manual ${safeTxHash} != protocol-kit ${sdkHash}`);
    }
    return {
        safeAddress, chainId, safeVersion: version, nonce: Number(d.nonce),
        multisendTo: d.to, operation: d.operation, innerDataHash: keccak256(d.data),
        domainSeparatorHash, messageHash, safeTxHash,
        ...(withTx ? { txData: d } : {}), // only for simulators; kept out of the recorded "hashes"
    };
}

// Compare recorded vs recomputed; returns list of differing keys.
export const diffHashes = (rec, cur) => Object.keys(cur).filter((k) => String(rec?.[k]).toLowerCase() !== String(cur[k]).toLowerCase());

export function printHashes(h) {
    console.log(`Safe:               ${h.safeAddress} (chainId ${h.chainId}, v${h.safeVersion}, nonce ${h.nonce})`);
    console.log(`MultiSend to:       ${h.multisendTo} (operation ${h.operation} = delegatecall)`);
    console.log(`inner data keccak:  ${h.innerDataHash}`);
    console.log(`domainSeparatorHash ${h.domainSeparatorHash}   (Ledger: "Domain hash")`);
    console.log(`messageHash         ${h.messageHash}   (Ledger: "Message hash")`);
    console.log(`safeTxHash          ${h.safeTxHash}   (Safe UI tx hash; Ledger "Safe tx hash")`);
}
