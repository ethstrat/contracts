#!/usr/bin/env node
// ESPN holder snapshot script.
//
// Zero dependencies — Node >=18's global `fetch` covers every JSON-RPC call.
//
// Env vars:
//   RPC_URL         required. Mainnet JSON-RPC endpoint.
//   SNAPSHOT_BLOCK  optional. Defaults to the `finalized` tag's block number.
//   ESPN_ADDRESS    optional. Defaults to 0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE.
//   SETTINGS_PATH   optional. Defaults to script/deployments/1/config/settings.json.
//
// Usage:
//   yarn snapshot:espn
//   yarn snapshot:selftest   (pure-function checks, no network)
//
// The snapshot block lives ONLY in the output filename and body
// (script/deployments/1/config/espn-holders-<block>.json) — it is never
// written to settings.json. Both Track A and Track B must be run against the
// same snapshot block.

import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";

const DEFAULT_ESPN_ADDRESS = "0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE";
const DEFAULT_SETTINGS_PATH = "script/deployments/1/config/settings.json";
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
// Found by binary-searching eth_getCode against mainnet on 2026-08-21; first block with code.
const ESPN_DEPLOY_BLOCK = 23182879;
const LOG_CHUNK_SIZE = 10000;
const RPC_BATCH_SIZE = 50;
const REORG_CONFIRMATIONS = 64;

function toHex(n) {
  return "0x" + BigInt(n).toString(16);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Bounded retry (3 attempts, exponential backoff) around a transient RPC
// failure such as a rate limit — the batch/single-call counterpart of the
// chunk-halving retry used for eth_getLogs below.
async function withRetry(fn) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (attempt >= 2) throw err;
      await sleep(2 ** attempt * 500);
    }
  }
}

async function rpcRequest(rpcUrl, method, params) {
  return withRetry(async () => {
    const res = await fetch(rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    const json = await res.json();
    if (json.error) throw new Error(`RPC error ${json.error.code}: ${json.error.message}`);
    return json.result;
  });
}

async function rpcBatch(rpcUrl, requests) {
  return withRetry(async () => {
    const res = await fetch(rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(requests.map((r) => ({ jsonrpc: "2.0", id: r.id, method: r.method, params: r.params }))),
    });
    const json = await res.json();
    return parseBatchResponse(json);
  });
}

// Reorders a raw JSON-RPC batch response array (which may arrive out of
// order) into results indexed 0..n-1 by request id. Throws on any error entry.
function parseBatchResponse(jsonArray) {
  if (!Array.isArray(jsonArray)) throw new Error(`expected batch array response, got: ${JSON.stringify(jsonArray)}`);
  const byId = new Map(jsonArray.map((entry) => [entry.id, entry]));
  const results = [];
  for (let id = 0; id < jsonArray.length; id++) {
    const entry = byId.get(id);
    if (!entry) throw new Error(`missing batch response for id ${id}`);
    if (entry.error) throw new Error(`RPC error ${entry.error.code}: ${entry.error.message}`);
    results.push(entry.result);
  }
  return results;
}

// Last 20 bytes of a 32-byte indexed-address log topic.
function topicToAddress(topic) {
  return "0x" + topic.slice(2).slice(24).toLowerCase();
}

// Splits an inclusive block range into two inclusive sub-ranges of near-equal size.
function halveChunk({ from, to }) {
  const size = to - from + 1;
  if (size <= 1) throw new Error(`range [${from}, ${to}] cannot be halved further`);
  const mid = from + Math.floor(size / 2) - 1;
  return [
    { from, to: mid },
    { from: mid + 1, to },
  ];
}

function sumBalances(balances) {
  let total = 0n;
  const values = balances instanceof Map ? balances.values() : Object.values(balances);
  for (const v of values) total += BigInt(v);
  return total;
}

function isRangeOrSizeError(err) {
  const msg = String(err && err.message ? err.message : err).toLowerCase();
  return /range|limit|too many|too large|exceed|10,?000|block count/.test(msg);
}

async function fetchLogsRange(rpcUrl, address, fromBlock, toBlock) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await rpcRequest(rpcUrl, "eth_getLogs", [
        { address, topics: [TRANSFER_TOPIC], fromBlock: toHex(fromBlock), toBlock: toHex(toBlock) },
      ]);
    } catch (err) {
      if (isRangeOrSizeError(err) && toBlock > fromBlock) {
        const [a, b] = halveChunk({ from: fromBlock, to: toBlock });
        const [logsA, logsB] = await Promise.all([
          fetchLogsRange(rpcUrl, address, a.from, a.to),
          fetchLogsRange(rpcUrl, address, b.from, b.to),
        ]);
        return logsA.concat(logsB);
      }
      if (attempt >= 2) throw err;
      await sleep(2 ** attempt * 250);
    }
  }
}

async function discoverAddresses(rpcUrl, espnAddress, fromBlock, toBlock) {
  const addresses = new Set();
  for (let start = fromBlock; start <= toBlock; start += LOG_CHUNK_SIZE) {
    const end = Math.min(start + LOG_CHUNK_SIZE - 1, toBlock);
    const logs = await fetchLogsRange(rpcUrl, espnAddress, start, end);
    for (const log of logs) {
      const from = topicToAddress(log.topics[1]);
      const to = topicToAddress(log.topics[2]);
      if (from !== ZERO_ADDRESS) addresses.add(from);
      if (to !== ZERO_ADDRESS) addresses.add(to);
    }
    process.stderr.write(`  scanned blocks ${start}-${end} (${addresses.size} addresses so far)\n`);
  }
  return addresses;
}

async function fetchBalances(rpcUrl, espnAddress, addresses, blockNumber) {
  const blockHex = toHex(blockNumber);
  const list = Array.from(addresses);
  const balances = new Map();
  for (let i = 0; i < list.length; i += RPC_BATCH_SIZE) {
    const batch = list.slice(i, i + RPC_BATCH_SIZE);
    const requests = batch.map((addr, idx) => ({
      id: idx,
      method: "eth_call",
      params: [{ to: espnAddress, data: "0x70a08231" + addr.slice(2).padStart(64, "0") }, blockHex],
    }));
    const results = await rpcBatch(rpcUrl, requests);
    results.forEach((res, idx) => balances.set(batch[idx], BigInt(res)));
  }
  return balances;
}

async function fetchIsContract(rpcUrl, addresses, blockNumber) {
  const blockHex = toHex(blockNumber);
  const flags = new Map();
  for (let i = 0; i < addresses.length; i += RPC_BATCH_SIZE) {
    const batch = addresses.slice(i, i + RPC_BATCH_SIZE);
    const requests = batch.map((addr, idx) => ({ id: idx, method: "eth_getCode", params: [addr, blockHex] }));
    const results = await rpcBatch(rpcUrl, requests);
    results.forEach((res, idx) => flags.set(batch[idx], res !== "0x"));
  }
  return flags;
}

function requireEnv(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`${name} is required`);
    process.exit(1);
  }
  return v;
}

async function main() {
  const rpcUrl = requireEnv("RPC_URL");
  const espnAddress = (process.env.ESPN_ADDRESS || DEFAULT_ESPN_ADDRESS).toLowerCase();
  const settingsPath = process.env.SETTINGS_PATH || DEFAULT_SETTINGS_PATH;

  // 1. Reorg guard, first.
  const head = Number(BigInt(await rpcRequest(rpcUrl, "eth_blockNumber", [])));

  let snapshotBlock;
  if (process.env.SNAPSHOT_BLOCK) {
    snapshotBlock = Number(process.env.SNAPSHOT_BLOCK);
  } else {
    const finalized = await rpcRequest(rpcUrl, "eth_getBlockByNumber", ["finalized", false]);
    snapshotBlock = Number(BigInt(finalized.number));
  }

  if (head - snapshotBlock < REORG_CONFIRMATIONS) {
    console.error(
      `snapshotBlock ${snapshotBlock} is only ${head - snapshotBlock} blocks behind head ${head}; ` +
        `need >= ${REORG_CONFIRMATIONS} (set SNAPSHOT_BLOCK to an older block)`,
    );
    process.exit(1);
  }

  // 2. Address discovery.
  console.error(`discovering ESPN holders: blocks ${ESPN_DEPLOY_BLOCK} -> ${snapshotBlock}`);
  const addresses = await discoverAddresses(rpcUrl, espnAddress, ESPN_DEPLOY_BLOCK, snapshotBlock);
  console.error(`found ${addresses.size} candidate addresses`);

  // 3. Balances from balanceOf at snapshotBlock.
  const balances = await fetchBalances(rpcUrl, espnAddress, addresses, snapshotBlock);

  // 4. Invariant: sum(balances) === totalSupply() at snapshotBlock. Hard fail on mismatch.
  const totalSupply = BigInt(await rpcRequest(rpcUrl, "eth_call", [{ to: espnAddress, data: "0x18160ddd" }, toHex(snapshotBlock)]));
  const sum = sumBalances(balances);
  if (sum !== totalSupply) {
    console.error(`INVARIANT FAILED: sum(balances)=${sum} != totalSupply=${totalSupply} at block ${snapshotBlock}`);
    process.exit(1);
  }

  // 5. Drop zero balances, after the invariant check.
  for (const [addr, bal] of balances) {
    if (bal === 0n) balances.delete(addr);
  }

  // 6. Flags. Exclude nothing by default.
  const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
  const excludedAddresses = new Set((settings.espnv3?.excludedAddresses ?? []).map((a) => a.toLowerCase()));
  const isContract = await fetchIsContract(rpcUrl, Array.from(balances.keys()), snapshotBlock);

  // 7. Output.
  const holders = Array.from(balances.entries())
    .map(([address, balance]) => ({
      address,
      balance: balance.toString(),
      isContract: isContract.get(address) ?? false,
      excluded: excludedAddresses.has(address),
    }))
    .sort((a, b) => (a.address < b.address ? -1 : a.address > b.address ? 1 : 0));

  const output = { snapshotBlock, totalSupply: totalSupply.toString(), holders };
  const outPath = `script/deployments/1/config/espn-holders-${snapshotBlock}.json`;
  writeFileSync(outPath, JSON.stringify(output, null, 2) + "\n");

  // 8. Summary to stderr (reference figures, not written to the file).
  const totalAssets = BigInt(await rpcRequest(rpcUrl, "eth_call", [{ to: espnAddress, data: "0x01e1d114" }, toHex(snapshotBlock)]));
  const navPerEspn = totalSupply === 0n ? 0n : (totalAssets * 10n ** 18n) / totalSupply;
  const contractCount = holders.filter((h) => h.isContract).length;
  const excludedCount = holders.filter((h) => h.excluded).length;

  console.error(`snapshotBlock: ${snapshotBlock}`);
  console.error(`holders:       ${holders.length}`);
  console.error(`contracts:     ${contractCount}`);
  console.error(`excluded:      ${excludedCount}`);
  console.error(`totalSupply:   ${totalSupply}`);
  console.error(`totalAssets:   ${totalAssets}`);
  console.error(`NAV per ESPN:  ${navPerEspn} (1e18 = 1.0)`);
  console.error(`wrote ${outPath}`);
}

function selftest() {
  // topicToAddress
  const topic = "0x" + "0".repeat(24) + "abcabcabcabcabcabcabcabcabcabcabcabcabc";
  assert.equal(topicToAddress(topic), "0xabcabcabcabcabcabcabcabcabcabcabcabcabc");
  assert.equal(topicToAddress("0x" + "0".repeat(64)), ZERO_ADDRESS);

  // halveChunk: even and odd sizes.
  assert.deepEqual(halveChunk({ from: 0, to: 9999 }), [
    { from: 0, to: 4999 },
    { from: 5000, to: 9999 },
  ]);
  assert.deepEqual(halveChunk({ from: 1, to: 10 }), [
    { from: 1, to: 5 },
    { from: 6, to: 10 },
  ]);
  assert.throws(() => halveChunk({ from: 5, to: 5 }));

  // parseBatchResponse: out-of-order results reordered by id; throws on error entry.
  assert.deepEqual(
    parseBatchResponse([
      { id: 1, result: "0x2" },
      { id: 0, result: "0x1" },
    ]),
    ["0x1", "0x2"],
  );
  assert.throws(() => parseBatchResponse([{ id: 0, error: { code: -32000, message: "boom" } }]));
  assert.throws(() => parseBatchResponse({ not: "an array" }));

  // sumBalances: Map and plain object.
  assert.equal(
    sumBalances(
      new Map([
        ["a", 5n],
        ["b", 10n],
      ]),
    ),
    15n,
  );
  assert.equal(sumBalances({ a: "5", b: "10" }), 15n);
  assert.equal(sumBalances(new Map()), 0n);

  console.error("selftest OK");
  process.exit(0);
}

if (process.argv.includes("--selftest")) {
  selftest();
} else {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
