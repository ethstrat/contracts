// Convertible note go-live liquidity (Mon 19 Oct 2026 02:00 UTC) Safe batch, sent from the main Safe:
//   (a) 0xaA1A (liquidity Safe): 400,000 USDS single-sided CDT/USDS Uniswap v4 position, price $1 down to ~$0, pool opened at $1.
//   (b) 0x0cbe (redemption Safe): Seaport bid, offer 150,000 USDS for CDT at $0.70, PARTIAL_OPEN, validated on-chain.
// Funding is NOT part of the batch: fund 0xaA1A with >= 400,000 USDS and 0x0cbe with >= 150,000 USDS before execution
// (only the underfunded Safe's own leg reverts; the other leg is independent). The generator only WARNs when underfunded and writes Tenderly
// `stateOverrides` for the missing balances so the simulation works before funding.
// Library: imported by generate-golive-monday.mjs (the Monday batch); exports the tx list, stateOverrides, Seaport order.
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { AbiCoder, Interface, JsonRpcProvider, Contract, ZeroAddress, ZeroHash, keccak256, toUtf8Bytes, zeroPadValue, toBeHex, getAddress } from "ethers";

// ---- CONFIG ----
const USDS_IN_LP = 400_000n * 10n ** 18n;
const FEE = 3000, TICK_SPACING = 60;
const OFFER = 150_000n * 10n ** 18n; // USDS offered by the Seaport order
const ASK_PRICE_X100 = 70n; // $0.70 per CDT
const GRID = 10n ** 9n; // partial-fill grid (wei): offer and ask are multiples, so any n/1e9 fraction is exact
export const START_TIME = 1792375200; // 2026-10-19 02:00:00 UTC
export const END_TIME = START_TIME + 30 * 86400;
const SALT = BigInt(keccak256(toUtf8Bytes("cdt-usds-bid-1")));
const Q96 = 2n ** 96n;
const ROOT = "script/deployments/1/config/";
const J = (f) => JSON.parse(readFileSync(ROOT + f, "utf8"));
const dep = J("deploymentAddresses.json"), ext = J("externalAddresses.json"), { multisigs } = J("internalAddresses.json").protocol;
const SAFE = multisigs.main, LP_SAFE = multisigs.liquidity, RED = multisigs.redemption;
const CDT = dep.cdt, USDS = ext["sky-money"].USDS;
export const SEAPORT = ext.opensea.seaport;
const { poolManager, positionManager: POSM, permit2: PERMIT2, stateView } = ext["uniswap-v4"];

if (!process.env.RPC_URL) throw new Error("set RPC_URL (node --env-file=.env)");
const provider = new JsonRpcProvider(process.env.RPC_URL);

// ---- MATH ----
// Port of Uniswap TickMath.getSqrtPriceAtTick (v3/v4), BigInt.
function sqrtAtTick(tick) {
    const abs = BigInt(Math.abs(tick));
    let r = abs & 1n ? 0xfffcb933bd6fad37aa2d162d1a594001n : 1n << 128n;
    const k = [
        [0x2n, 0xfff97272373d413259a46990580e213an], [0x4n, 0xfff2e50f5f656932ef12357cf3c7fdccn], [0x8n, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
        [0x10n, 0xffcb9843d60f6159c9db58835c926644n], [0x20n, 0xff973b41fa98c081472e6896dfb254c0n], [0x40n, 0xff2ea16466c96a3843ec78b326b52861n],
        [0x80n, 0xfe5dee046a99a2a811c461f1969c3053n], [0x100n, 0xfcbe86c7900a88aedcffc83b479aa3a4n], [0x200n, 0xf987a7253ac413176f2b074cf7815e54n],
        [0x400n, 0xf3392b0822b70005940c7a398e4b70f3n], [0x800n, 0xe7159475a2c29b7443b29c7fa6e889d9n], [0x1000n, 0xd097f3bdfd2022b8845ad8f792aa5825n],
        [0x2000n, 0xa9f746462d870fdf8a65dc1f90e061e5n], [0x4000n, 0x70d869a156d2a1b890bb3df62baf32f7n], [0x8000n, 0x31be135f97d08fd981231505542fcfa6n],
        [0x10000n, 0x9aa508b5b7a84e1c677de54f3e99bc9n], [0x20000n, 0x5d6af8dedb81196699c329225ee604n], [0x40000n, 0x2216e584f5fa1ea926041bedfe98n],
        [0x80000n, 0x48a170391f7dc42444e8fa2n],
    ];
    for (const [bit, c] of k) if (abs & bit) r = (r * c) >> 128n;
    if (tick > 0) r = (2n ** 256n - 1n) / r;
    return (r >> 32n) + (r % (1n << 32n) === 0n ? 0n : 1n);
}
const minUsableTick = -(887272 - (887272 % TICK_SPACING)); // -887220
const sqrtLow = sqrtAtTick(minUsableTick);
assert.equal(sqrtLow, 4306310044n, "sqrtAtTick(-887220) mismatch"); // TickMath rounds up; a Decimal floor calc gives ...043
// getLiquidityForAmount1(sqrtLow, 2^96 (tick 0), usds), then step down until v4's round-up amount1 <= usds.
const diff = Q96 - sqrtLow;
let L = (USDS_IN_LP * Q96) / diff;
while ((L * diff + Q96 - 1n) / Q96 > USDS_IN_LP) L--;
assert.ok(L <= 400000000000000000021741n && L > 400000000000000000021741n - 10n ** 6n, `liquidity ${L} outside expected range`);

// ---- PREFLIGHT ----
const erc = (t) => new Contract(t, ["function decimals() view returns (uint8)", "function balanceOf(address) view returns (uint256)"], provider);
const safeC = (s) => new Contract(s, ["function getOwners() view returns (address[])", "function getThreshold() view returns (uint256)", "function nonce() view returns (uint256)"], provider);
for (const s of [LP_SAFE, RED]) {
    assert.deepEqual([...(await safeC(s).getOwners())], [SAFE], `${s} owners != [main Safe]`);
    assert.equal(await safeC(s).getThreshold(), 1n, `${s} threshold != 1`);
}
for (const t of [CDT, USDS]) assert.equal(await erc(t).decimals(), 18n, `${t} decimals != 18`);
const posm = new Contract(POSM, ["function poolManager() view returns (address)", "function permit2() view returns (address)"], provider);
assert.equal(getAddress(await posm.poolManager()), getAddress(poolManager), "PositionManager.poolManager mismatch");
assert.equal(getAddress(await posm.permit2()), getAddress(PERMIT2), "PositionManager.permit2 mismatch");
assert.ok(BigInt(CDT) < BigInt(USDS), "expected CDT < USDS (CDT = currency0)");
const key = [CDT, USDS, FEE, TICK_SPACING, ZeroAddress];
const coder = AbiCoder.defaultAbiCoder();
const poolId = keccak256(coder.encode(["(address,address,uint24,int24,address)"], [key]));
const slot0 = await new Contract(stateView, ["function getSlot0(bytes32) view returns (uint160,int24,uint24,uint24)"], provider).getSlot0(poolId);
assert.equal(slot0[0], 0n, `pool ${poolId} already initialized (sqrtPriceX96 ${slot0[0]})`);
const seaport = new Contract(SEAPORT, [
    "function getCounter(address) view returns (uint256)",
    "function getOrderHash((address offerer,address zone,(uint8 itemType,address token,uint256 identifierOrCriteria,uint256 startAmount,uint256 endAmount)[] offer,(uint8 itemType,address token,uint256 identifierOrCriteria,uint256 startAmount,uint256 endAmount,address recipient)[] consideration,uint8 orderType,uint256 startTime,uint256 endTime,bytes32 zoneHash,uint256 salt,bytes32 conduitKey,uint256 counter)) view returns (bytes32)",
], provider);
export const counter = await seaport.getCounter(RED);

const warnings = [];
export const overrides = {};
for (const [name, holder, need] of [["liquidity Safe", LP_SAFE, USDS_IN_LP], ["redemption Safe", RED, OFFER]]) {
    const bal = await erc(USDS).balanceOf(holder);
    console.log(`USDS balance ${name} ${holder}: ${bal} (need ${need})`);
    if (bal < need) {
        warnings.push(`WARN: ${name} ${holder} holds ${bal} USDS < ${need}; its leg reverts until funded`);
        // USDS balanceOf is mapping at slot 2
        const slot = keccak256(coder.encode(["address", "uint256"], [holder, 2]));
        overrides[USDS] = { storage: { ...(overrides[USDS]?.storage ?? {}), [slot]: zeroPadValue(toBeHex(need), 32) } };
    }
}
warnings.forEach((w) => console.warn(w));

// ---- SEAPORT ORDER ----
export const ask = ((OFFER * 100n) / ASK_PRICE_X100 + GRID - 1n) / GRID * GRID; // ceil to grid: offerer favored by dust
assert.equal(OFFER % GRID, 0n);
export const order = {
    offerer: RED, zone: ZeroAddress,
    offer: [{ itemType: 1, token: USDS, identifierOrCriteria: 0n, startAmount: OFFER, endAmount: OFFER }],
    consideration: [{ itemType: 1, token: CDT, identifierOrCriteria: 0n, startAmount: ask, endAmount: ask, recipient: RED }],
    orderType: 1, // PARTIAL_OPEN
    startTime: BigInt(START_TIME), endTime: BigInt(END_TIME), zoneHash: ZeroHash, salt: SALT, conduitKey: ZeroHash,
};
export const orderHash = await seaport.getOrderHash({ ...order, counter });
const orderTuple = [order.offerer, order.zone, order.offer.map(Object.values), order.consideration.map(Object.values), order.orderType, order.startTime, order.endTime, order.zoneHash, order.salt, order.conduitKey, 1n];
const VALIDATE = "validate(((address,address,(uint8,address,uint256,uint256,uint256)[],(uint8,address,uint256,uint256,uint256,address)[],uint8,uint256,uint256,bytes32,uint256,bytes32,uint256),bytes)[])";

// ---- TRANSACTIONS (in order) ----
const tx = (label, to, signature, args) => ({ label, to, signature, args: args.map((x) => (typeof x === "bigint" ? x.toString() : x)) });
const ownerSig = "0x" + SAFE.slice(2).toLowerCase().padStart(64, "0") + "0".repeat(64) + "01"; // approved-hash style (v=1, r=SAFE)
// Nested call: main Safe -> safe.execTransaction(to, 0, abi(signature,args))
const via = (safe, label, to, signature, args) => {
    const data = new Interface([`function ${signature}`]).encodeFunctionData(signature.split("(")[0], args);
    return tx(`${safe === LP_SAFE ? "liquidity Safe" : "redemption Safe"}: ${label}`, safe, "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)", [to, 0n, data, 0, 0n, 0n, 0n, ZeroAddress, ZeroAddress, ownerSig]);
};
const MINT = 0x02, SETTLE_PAIR = 0x0d;
const mintParams = coder.encode(["(address,address,uint24,int24,address)", "int24", "int24", "uint256", "uint128", "uint128", "address", "bytes"], [key, minUsableTick, 0, L, 0n, USDS_IN_LP, LP_SAFE, "0x"]);
const settleParams = coder.encode(["address", "address"], [CDT, USDS]);
const unlockData = coder.encode(["bytes", "bytes[]"], [new Uint8Array([MINT, SETTLE_PAIR]), [mintParams, settleParams]]);
const posmI = new Interface(["function initializePool((address,address,uint24,int24,address),uint160) returns (int24)", "function modifyLiquidities(bytes,uint256)"]);
const multicall = [posmI.encodeFunctionData("initializePool", [key, Q96]), posmI.encodeFunctionData("modifyLiquidities", [unlockData, 2n ** 256n - 1n])];
export const transactions = [
    via(LP_SAFE, "USDS.approve(Permit2, 400,000)", USDS, "approve(address,uint256)", [PERMIT2, USDS_IN_LP]),
    via(LP_SAFE, "Permit2.approve(USDS, PositionManager, 400,000, max expiry)", PERMIT2, "approve(address,address,uint160,uint48)", [USDS, POSM, USDS_IN_LP, 2n ** 48n - 1n]),
    via(LP_SAFE, "PositionManager.multicall: initializePool CDT/USDS at $1 (fee 3000, spacing 60) + mint USDS-only position ticks [-887220, 0] to liquidity Safe", POSM, "multicall(bytes[])", [multicall]),
    via(RED, "USDS.approve(Seaport, 150,000)", USDS, "approve(address,uint256)", [SEAPORT, OFFER]),
    via(RED, `Seaport.validate order ${orderHash} (offer 150,000 USDS for ${ask} CDT, PARTIAL_OPEN, ${START_TIME}-${END_TIME})`, SEAPORT, VALIDATE, [[[orderTuple, "0x"]]]),
];

// ---- VALIDATION: calldata round-trips through decode/encode ----
for (const t of transactions) {
    const i = new Interface([`function ${t.signature}`]);
    const name = t.signature.split("(")[0];
    const data = i.encodeFunctionData(name, t.args);
    assert.equal(i.encodeFunctionData(name, i.decodeFunctionData(name, data)), data);
}
