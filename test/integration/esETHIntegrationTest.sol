// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {esETH, ILegacyVaultTypes, IWeETH} from "../../src/esETH.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

// Lido stETH V2: handleOracleReport() is the only function that actually updates the
// rate (stEthPerToken).  In Lido V2, EL rewards received via receiveELRewards() are
// held as "pending" and only become part of getTotalPooledEther() when the
// AccountingOracle calls handleOracleReport() to distribute them alongside CL rewards.
interface ILidoStEth {
    function handleOracleReport(
        uint256 _reportTimestamp,
        uint256 _timeElapsed,
        uint256 _clValidators,
        uint256 _clBalance,
        uint256 _withdrawalVaultBalance,
        uint256 _elRewardsVaultBalance,
        uint256 _sharesRequestedToBurn,
        uint256[] calldata _withdrawalFinalizationBatches,
        uint256 _simulatedShareRate
    ) external returns (uint256[2] memory postRebaseAmounts);

    function getBeaconStat() external view returns (
        uint256 depositedValidators,
        uint256 beaconValidators,
        uint256 beaconBalance
    );

    function getTotalPooledEther() external view returns (uint256);
    function getTotalShares() external view returns (uint256);
}

/**
 * @title esETH Integration Tests
 * @notice Full mint -> yield-advance -> harvestYield -> redeem cycle for every supported token type.
 *
 * @dev Run with:
 *      FOUNDRY_PROFILE=integration forge test \
 *        --fork-url 'https://mainnet.gateway.tenderly.co/...' -vv
 *
 *  Each test verifies five properties:
 *
 *   1. RATE AT FORK_BLOCK
 *      The on-chain conversion of 1e18 underlying to ETH is read and logged.
 *      A cast call comment lets the reader independently verify the exact value.
 *
 *   2. MINT PRODUCES CORRECT esETH
 *      esETH minted = depositAmount * rate / 1e18.
 *      For 1:1 tokens (WETH, aWETH) this equals the deposit amount exactly.
 *      For yield-bearing tokens (wstETH, rETH, weETH) it is strictly greater.
 *      The assertion also guards against double-scaling bugs where the rate is
 *      applied twice.
 *
 *   3. YIELD ADVANCE (one year)
 *      - Oracle-based tokens (wstETH, rETH, weETH): vm.rollFork resets
 *        locally-deployed contract state, so yield is simulated by dealing extra
 *        tokens into the esETH contract. Cast call comments at YIELD_BLOCK show
 *        what the real oracle value would be for independent verification.
 *      - aWETH: Aave interest is purely timestamp-driven. vm.warp advances
 *        block.timestamp without resetting storage; a subsequent tiny pool.supply()
 *        forces updateState() which credits the elapsed interest to all aToken holders.
 *      - WETH: no yield mechanism exists; step 3/4 confirm harvestYield is zero.
 *
 *   4. HARVEST CAPTURES EXACT SURPLUS
 *      harvestYield() mints new esETH equal to the esETH-denominated surplus backing.
 *
 *   5. REDEEM IS THE INVERSE OF MINT
 *      redeem(token, tokenAmount) burns (convertToETH(tokenAmount) + 1) esETH and
 *      returns exactly tokenAmount underlying tokens.
 *      Because rate > 1 for yield-bearing tokens, tokenAmount < the original deposit:
 *      1 esETH buys LESS than 1 wstETH/rETH/weETH, and EXACTLY 1 WETH/aWETH.
 */
contract esETHIntegrationTest is Test {
    esETH public esETHContract;

    // ---------------------------------------------------------------------------
    // Mainnet addresses
    // ---------------------------------------------------------------------------
    address public constant WETH                  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WSTETH                = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant STETH                 = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant RETH                  = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address public constant AWETH                 = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address public constant WEETH                 = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address public constant AAVE_V3_POOL          = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    // Lido V2 AccountingOracle: the only address allowed to call stETH.handleOracleReport().
    // Verify: cast call 0xC1d0b3DE6792Bf6b4b37EccdcC24e45978Cfd2Eb \
    //           "accountingOracle()(address)" --block 22000000 --rpc-url $RPC
    address public constant LIDO_ACCOUNTING_ORACLE = 0x852deD011285fe67063a08005c71a85690503Cee;

    address public owner = address(0x1);

    // FORK_BLOCK = ~Mar 2025 (block 22 000 000)
    uint256 public constant FORK_BLOCK  = 22_000_000;
    // YIELD_BLOCK = ~Aug 2025 (~4.6 months later); used only in cast call comments below.
    uint256 public constant YIELD_BLOCK = 23_000_000;

    // ---------------------------------------------------------------------------
    // Setup: deploy esETH and enable all supported tokens
    // ---------------------------------------------------------------------------

    function setUp() public {
        vm.rollFork(FORK_BLOCK);
        require(block.chainid == 1, "Must be on mainnet fork");

        // Deploy esETH contract
        ITripwireController ctrl = ITripwireController(address(new TripwireController()));
        vm.prank(owner);
        esETHContract = new esETH(owner, WETH, ctrl, owner);

        vm.startPrank(owner);
        esETHContract.setTokenConfig(WETH,   esETH.TokenType.ERC20,  true, true);
        esETHContract.setTokenConfig(WSTETH, esETH.TokenType.WSTETH, true, true);
        esETHContract.setTokenConfig(RETH,   esETH.TokenType.RETH,   true, true);
        esETHContract.setTokenConfig(AWETH,  esETH.TokenType.AWETH,  true, true);
        esETHContract.setTokenConfig(WEETH,  esETH.TokenType.WEETH,  true, true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    function _mintEsETH(address token, address user, uint256 amount) internal returns (uint256 minted) {
        deal(token, user, amount);
        vm.startPrank(user);
        IERC20(token).approve(address(esETHContract), amount);
        minted = esETHContract.mint(token, amount, user);
        vm.stopPrank();
    }

    function _harvest(address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        esETHContract.harvestYield(tokens);
    }

    // ===========================================================================
    // 1. WETH  (ERC20 – 1:1 with ETH, no yield)
    // ===========================================================================
    //
    // RATE AT FORK_BLOCK
    //   WETH is wrapped ETH: 1 WETH == 1 ETH by definition (no oracle).
    //   cast call 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
    //     "balanceOf(address)(uint256)" 0x0000000000000000000000000000000000000000 \
    //     --block 22000000 --rpc-url $RPC
    //   -> verify any balance; the point is there is no conversion rate to query.
    //
    // YIELD ADVANCE
    //   WETH does not generate yield while sitting in a contract. Steps 3 & 4
    //   confirm that harvestYield captures exactly zero additional esETH.
    //
    // REDEEM (inverse of mint)
    //   1 esETH redeems exactly 1 WETH. The contract adds +1 wei of rounding
    //   protection, so redeeming R WETH burns (R + 1) esETH.

    function testFork_WETH() public {
        address user = makeAddr("weth_user");
        uint256 depositAmt = 2e18; // 2 WETH gives headroom for the +1 wei redeem rounding

        // --- 1. Rate at FORK_BLOCK: 1 WETH = 1 ETH (1:1) ---
        uint256 rate = esETHContract.getETHValue(WETH, 1e18);
        assertEq(rate, 1e18, "WETH: getETHValue must be exactly 1:1");
        console2.log("WETH rate (1e18 in, ETH out):", rate);

        // --- 2. Mint: esETH = depositAmt * 1 (1:1, no rate multiplier) ---
        uint256 minted = _mintEsETH(WETH, user, depositAmt);
        assertEq(minted, depositAmt, "WETH: minted esETH must equal deposited WETH exactly");

        // --- 3 & 4. No yield: harvestYield must capture zero ---
        uint256 ownerBalBefore = esETHContract.balanceOf(owner);
        _harvest(WETH);
        assertEq(esETHContract.balanceOf(owner), ownerBalBefore, "WETH: no yield to harvest");

        // --- 5. Redeem: 1 esETH returns exactly 1 WETH ---
        // Redeeming R WETH burns (R + 1) esETH due to rounding protection.
        uint256 redeemAmt    = depositAmt / 2;
        uint256 expectedBurn = redeemAmt + 1;
        vm.prank(user);
        uint256 burned = esETHContract.redeem(WETH, redeemAmt, user);

        assertEq(burned, expectedBurn, "WETH: esETH burned must equal redeemAmt + 1 wei");
        assertEq(IERC20(WETH).balanceOf(user), redeemAmt, "WETH: user receives exact WETH");

        console2.log("WETH minted:", minted);
        console2.log("WETH redeemed:", redeemAmt, "| esETH burned:", burned);
    }

    // ===========================================================================
    // 2. wstETH  (WSTETH – stEthPerToken oracle, validator rewards)
    // ===========================================================================
    //
    // RATE AT FORK_BLOCK
    //   cast call 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 \
    //     "stEthPerToken()(uint256)" \
    //     --block 22000000 --rpc-url $RPC
    //   -> ~1.196e18  (1 wstETH is worth ~1.196 stETH/ETH at block 22 000 000)
    //
    // HOW stEthPerToken INCREASES
    //   stEthPerToken = stETH.getTotalPooledEther() / stETH.getTotalShares() * 1e18
    //   It rises when totalPooledEther grows without new shares being issued, which
    //   happens in two ways in the real protocol:
    //     a) Consensus-layer validator rewards (reported via AccountingOracle)
    //     b) Execution-layer rewards (MEV / priority fees) sent to stETH via
    //        stETH.receiveELRewards(), callable only by the EL rewards vault.
    //
    // YIELD ADVANCE STRATEGY (this test)
    //   We credit EL rewards directly by impersonating the EL rewards vault and
    //   calling stETH.receiveELRewards{value: X}().  This is the real on-chain
    //   function — no mocking or storage manipulation.  After the call, every
    //   wstETH token the esETH contract holds is worth more esETH.
    //
    //   Verify the EL rewards vault address:
    //     cast call 0xC1d0b3DE6792Bf6b4b37EccdcC24e45978Cfd2Eb \
    //       "elRewardsVault()(address)" --block 22000000 --rpc-url $RPC
    //     -> 0x388C818CA8B9251b393131C08a736A67ccB19297
    //
    //   Observe the real stEthPerToken increase at YIELD_BLOCK:
    //     cast call 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 \
    //       "stEthPerToken()(uint256)" --block 23000000 --rpc-url $RPC
    //     -> ~1.204e18
    //
    // REDEEM (inverse of mint)
    //   rate > 1, so 1 esETH redeems LESS than 1 wstETH.
    //   E.g. at rate 1.196: redeeming 1e18 esETH gives ~0.836 wstETH back.

    function testFork_WstETH() public {
        address user = makeAddr("wsteth_user");
        uint256 depositAmt = 2e18;

        // --- 1. Rate at FORK_BLOCK ---
        uint256 rateAtMint = ILegacyVaultTypes(WSTETH).stEthPerToken();
        assertGt(rateAtMint, 1e18,   "wstETH: stEthPerToken must be > 1e18 at fork block");
        assertLt(rateAtMint, 1.5e18, "wstETH: stEthPerToken sanity upper bound");
        console2.log("wstETH stEthPerToken at FORK_BLOCK:", rateAtMint);

        // --- 2. Mint: esETH = depositAmt * rateAtMint / 1e18 (> depositAmt because rate > 1) ---
        uint256 minted = _mintEsETH(WSTETH, user, depositAmt);
        assertEq(minted, depositAmt * rateAtMint / 1e18,
            "wstETH: minted esETH must equal depositAmt * stEthPerToken / 1e18");
        assertGt(minted, depositAmt,
            "wstETH: minted esETH > deposited tokens because stEthPerToken > 1");

        // --- 3. Yield advance: submit oracle report with higher CL balance ---
        // wstETH's rate is stEthPerToken = getTotalPooledEther() / getTotalShares() * 1e18.
        // In Lido V2 the ONLY function that increases getTotalPooledEther() is
        // handleOracleReport(), called by the AccountingOracle.  receiveELRewards() merely
        // holds ETH as "pending" — it does NOT change the rate until the oracle distributes
        // it.  We therefore impersonate the AccountingOracle and submit a report that raises
        // the beacon-chain (consensus-layer) balance to reflect one year of staking rewards.
        //
        // Verify the AccountingOracle address:
        //   cast call 0xC1d0b3DE6792Bf6b4b37EccdcC24e45978Cfd2Eb \
        //     "accountingOracle()(address)" --block 22000000 --rpc-url $RPC
        //   -> 0x852deD011285fe67063a08005c71a85690503Cee
        //
        // _simulatedShareRate is the post-rebase share rate the oracle pre-computed off-chain
        // (via a static simulation call); we reproduce that computation here.
        (, uint256 beaconValidators, uint256 beaconBalance) = ILidoStEth(STETH).getBeaconStat();
        uint256 preTotalPooled = ILidoStEth(STETH).getTotalPooledEther();
        uint256 preTotalShares = ILidoStEth(STETH).getTotalShares();

        // ~4.5 % annual APR on the beacon balance
        uint256 clRewards    = beaconBalance * 45 / 1000;
        uint256 newClBalance = beaconBalance + clRewards;
        uint256 simulatedShareRate = (preTotalPooled + clRewards) * 1e27 / preTotalShares;

        vm.warp(block.timestamp + 365 days);
        vm.prank(LIDO_ACCOUNTING_ORACLE);
        ILidoStEth(STETH).handleOracleReport(
            block.timestamp,        // _reportTimestamp
            365 days,               // _timeElapsed
            beaconValidators,       // _clValidators (unchanged)
            newClBalance,           // _clBalance    (increased by annual rewards)
            0,                      // _withdrawalVaultBalance
            0,                      // _elRewardsVaultBalance
            0,                      // _sharesRequestedToBurn
            new uint256[](0),       // _withdrawalFinalizationBatches
            simulatedShareRate      // _simulatedShareRate
        );

        uint256 rateAfterRebase = ILegacyVaultTypes(WSTETH).stEthPerToken();
        assertGt(rateAfterRebase, rateAtMint,
            "wstETH: stEthPerToken must be higher after oracle report");
        console2.log("wstETH stEthPerToken after oracle report:", rateAfterRebase);

        // --- 4. Harvest: capture the rate-increase surplus as esETH ---
        // The same depositAmt wstETH is now valued at rateAfterRebase, which exceeds
        // the totalMinted recorded at mint time (rateAtMint).
        // surplus = depositAmt * rateAfterRebase / 1e18 - minted
        uint256 expectedYield = depositAmt * rateAfterRebase / 1e18 - minted;
        _harvest(WSTETH);
        assertEq(esETHContract.balanceOf(owner), expectedYield,
            "wstETH: harvestYield must mint exactly the rate-increase surplus as esETH");
        console2.log("wstETH yield harvested (from real rate increase):", expectedYield);

        // --- 5. Redeem: fewer wstETH returned because post-rebase rate > 1 ---
        // redeemAmt chosen so that burned ≈ minted / 2.
        // burned = redeemAmt * rateAfterRebase / 1e18 + 1
        uint256 redeemAmt    = (minted / 2 - 1) * 1e18 / rateAfterRebase;
        uint256 expectedBurn = redeemAmt * rateAfterRebase / 1e18 + 1;
        assertLe(expectedBurn, esETHContract.balanceOf(user), "sanity: user has enough esETH");
        assertLt(redeemAmt, depositAmt / 2,
            "wstETH: wstETH returned is less than half the deposit (rate > 1)");

        vm.prank(user);
        uint256 burned = esETHContract.redeem(WSTETH, redeemAmt, user);

        assertEq(burned, expectedBurn,
            "wstETH: esETH burned must equal redeemAmt * stEthPerToken / 1e18 + 1");
        assertEq(IERC20(WSTETH).balanceOf(user), redeemAmt,
            "wstETH: user receives the exact requested wstETH amount");

        console2.log("wstETH minted esETH:  ", minted, "| deposited wstETH:", depositAmt);
        console2.log("wstETH redeemed:       ", redeemAmt, "| esETH burned:", burned);
    }

    // ===========================================================================
    // 3. rETH  (RETH – getExchangeRate oracle, Rocket Pool node operators)
    // ===========================================================================
    //
    // RATE AT FORK_BLOCK
    //   cast call 0xae78736Cd615f374D3085123A210448E74Fc6393 \
    //     "getExchangeRate()(uint256)" \
    //     --block 22000000 --rpc-url $RPC
    //   -> ~1.108e18  (1 rETH is worth ~1.108 ETH at block 22 000 000)
    //
    // RATE AT YIELD_BLOCK
    //   cast call 0xae78736Cd615f374D3085123A210448E74Fc6393 \
    //     "getExchangeRate()(uint256)" \
    //     --block 23000000 --rpc-url $RPC
    //   -> ~1.115e18  (rate increases as Rocket Pool node operators earn rewards)
    //
    // YIELD ADVANCE STRATEGY: same deal-extra-tokens approach as wstETH (see above).
    //
    // REDEEM (inverse of mint)
    //   rate > 1, so 1 esETH redeems LESS than 1 rETH.
    //   E.g. at rate 1.108: redeeming 1e18 esETH gives ~0.902 rETH back.

    function testFork_RETH() public {
        address user = makeAddr("reth_user");
        uint256 depositAmt = 2e18;

        // --- 1. Rate at FORK_BLOCK ---
        uint256 rate = ILegacyVaultTypes(RETH).getExchangeRate();
        assertGt(rate, 1e18,   "rETH: getExchangeRate must be > 1e18 at fork block");
        assertLt(rate, 1.5e18, "rETH: getExchangeRate sanity upper bound");
        console2.log("rETH getExchangeRate at FORK_BLOCK:", rate);

        // --- 2. Mint: esETH = depositAmt * rate / 1e18 ---
        uint256 minted = _mintEsETH(RETH, user, depositAmt);
        assertEq(minted, depositAmt * rate / 1e18,
            "rETH: minted esETH must equal depositAmt * getExchangeRate / 1e18");
        assertGt(minted, depositAmt,
            "rETH: minted esETH > deposited tokens because getExchangeRate > 1");

        // --- 3. Yield advance: deal ~5% extra rETH to simulate oracle rate increase ---
        uint256 extraTokens = depositAmt / 20;
        deal(RETH, address(esETHContract),
            IERC20(RETH).balanceOf(address(esETHContract)) + extraTokens);

        // --- 4. Harvest ---
        uint256 expectedYield = extraTokens * rate / 1e18;
        _harvest(RETH);
        assertEq(esETHContract.balanceOf(owner), expectedYield,
            "rETH: harvestYield must mint exactly the esETH-valued surplus");

        // --- 5. Redeem: fewer rETH returned than deposited (rate > 1) ---
        uint256 redeemAmt    = (minted / 2 - 1) * 1e18 / rate;
        uint256 expectedBurn = redeemAmt * rate / 1e18 + 1;
        assertLe(expectedBurn, esETHContract.balanceOf(user), "sanity: user has enough esETH");
        assertLt(redeemAmt, depositAmt / 2,
            "rETH: rETH returned is less than half the deposit (rate > 1)");

        vm.prank(user);
        uint256 burned = esETHContract.redeem(RETH, redeemAmt, user);

        assertEq(burned, expectedBurn,
            "rETH: esETH burned must equal redeemAmt * getExchangeRate / 1e18 + 1");
        assertEq(IERC20(RETH).balanceOf(user), redeemAmt,
            "rETH: user receives the exact requested rETH amount");

        console2.log("rETH minted esETH:  ", minted, "| deposited rETH:", depositAmt);
        console2.log("rETH yield harvested:", expectedYield);
        console2.log("rETH redeemed:       ", redeemAmt, "| esETH burned:", burned);
    }

    // ===========================================================================
    // 4. aWETH  (AWETH – Aave V3 rebasing, timestamp-driven interest)
    // ===========================================================================
    //
    // RATE AT FORK_BLOCK
    //   aWETH is always 1:1 with WETH. Yield manifests as balance growth, not
    //   a rate > 1. The Aave liquidity index tracks accrued interest, but
    //   balanceOf() already incorporates it - no additional scaling is needed.
    //
    //   Verify the 1:1 peg and that interest has genuinely accrued (scaledTotalSupply
    //   < totalSupply at any live block):
    //   cast call 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8 \
    //     "scaledTotalSupply()(uint256)" --block 22000000 --rpc-url $RPC
    //   cast call 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8 \
    //     "totalSupply()(uint256)"       --block 22000000 --rpc-url $RPC
    //   -> totalSupply > scaledTotalSupply; the ratio is the liquidity index.
    //      Applying it again on top of balanceOf would double-count (historical bug).
    //
    // RATE AFTER 1 YEAR (vm.warp)
    //   Aave V3 WETH supply APY is approximately 1-3 %.  After vm.warp(+365 days)
    //   and a trigger supply(), the esETH contract's aWETH balance grows by that APY.
    //   cast call 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 \
    //     "getReserveNormalizedIncome(address)(uint256)" \
    //     0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
    //     --block 22000000 --rpc-url $RPC
    //   -> a ray-scaled (1e27) liquidity index; value grows over time.
    //
    // WHY vm.warp NOT vm.rollFork
    //   Aave interest is computed as: principal * linearInterest(rate, elapsed_seconds).
    //   vm.warp advances block.timestamp without resetting EVM storage, so the esETH
    //   contract's scaledBalance slot is preserved. vm.rollFork would clear it, wiping
    //   the position. A subsequent tiny pool.supply() forces Aave to call updateState()
    //   and rebase all aToken holders' balances.
    //
    // REDEEM (inverse of mint)
    //   aWETH is 1:1 post-rebase: 1 esETH still redeems exactly 1 aWETH.

    function testFork_AWETH() public {
        address user = makeAddr("aweth_user");
        uint256 wethToSupply = 2e18;

        // --- 1. Rate at FORK_BLOCK: 1 aWETH = 1 ETH (1:1, balance already rebased) ---
        uint256 rate = esETHContract.getETHValue(AWETH, 1e18);
        assertEq(rate, 1e18, "aWETH: getETHValue must be exactly 1:1 (no index scaling on top of balance)");
        console2.log("aWETH rate (1e18 in, ETH out):", rate);

        // --- 2. Mint: supply real WETH to Aave to obtain genuine aWETH, then mint esETH ---
        // Using pool.supply() (not deal) gives authentic Aave scaledBalance accounting,
        // which is the only way the rebase in step 3 will be credited correctly.
        deal(WETH, user, wethToSupply);
        vm.startPrank(user);
        IERC20(WETH).approve(AAVE_V3_POOL, wethToSupply);
        IAavePool(AAVE_V3_POOL).supply(WETH, wethToSupply, user, 0);
        vm.stopPrank();

        uint256 aWethReceived = IERC20(AWETH).balanceOf(user);
        assertApproxEqAbs(aWethReceived, wethToSupply, 1e12,
            "aWETH: received aWETH must approximately equal supplied WETH");

        vm.startPrank(user);
        IERC20(AWETH).approve(address(esETHContract), aWethReceived);
        uint256 minted = esETHContract.mint(AWETH, aWethReceived, user);
        vm.stopPrank();

        // 1:1 peg: esETH minted == aWETH deposited. Historical bug applied
        // (totalSupply/scaledTotalSupply) here, inflating by ~4%.
        assertEq(minted, aWethReceived,
            "aWETH: 1 aWETH must mint exactly 1 esETH (no liquidity-index double-scaling)");

        // --- 3. Yield advance: vm.warp 1 year; trigger pool interaction to rebase ---
        vm.warp(block.timestamp + 365 days);

        address triggerUser = makeAddr("aave_trigger");
        deal(WETH, triggerUser, 1e15);
        vm.startPrank(triggerUser);
        IERC20(WETH).approve(AAVE_V3_POOL, 1e15);
        IAavePool(AAVE_V3_POOL).supply(WETH, 1e15, triggerUser, 0);
        vm.stopPrank();

        uint256 contractAWeth = IERC20(AWETH).balanceOf(address(esETHContract));
        assertGt(contractAWeth, aWethReceived,
            "aWETH: 1-year rebasing must increase the contract aWETH balance (Aave interest credited)");
        console2.log("aWETH after 1 yr (rebased):", contractAWeth, "| deposited:", aWethReceived);

        // --- 4. Harvest: surplus = contractAWeth - totalMinted (still 1:1 per aWETH) ---
        uint256 expectedYield = contractAWeth - aWethReceived;
        _harvest(AWETH);
        assertApproxEqAbs(esETHContract.balanceOf(owner), expectedYield, 1,
            "aWETH: harvestYield must mint exactly the rebased surplus as esETH");
        console2.log("aWETH yield harvested:", expectedYield);

        // --- 5. Redeem: 1 esETH redeems exactly 1 aWETH (1:1 peg maintained post-rebase) ---
        uint256 redeemAmt    = aWethReceived / 2;
        uint256 expectedBurn = redeemAmt + 1;
        assertLe(expectedBurn, esETHContract.balanceOf(user), "sanity: user has enough esETH");

        vm.prank(user);
        uint256 burned = esETHContract.redeem(AWETH, redeemAmt, user);

        assertEq(burned, expectedBurn,
            "aWETH: esETH burned must equal redeemAmt + 1 (1:1 peg)");
        assertApproxEqAbs(IERC20(AWETH).balanceOf(user), redeemAmt, 1,
            "aWETH: user receives the correct aWETH amount");

        console2.log("aWETH redeemed:", redeemAmt, "| esETH burned:", burned);
    }

    // ===========================================================================
    // 5. weETH  (WEETH – getEETHByWeETH oracle, ether.fi restaking rewards)
    // ===========================================================================
    //
    // RATE AT FORK_BLOCK
    //   cast call 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee \
    //     "getEETHByWeETH(uint256)(uint256)" 1000000000000000000 \
    //     --block 22000000 --rpc-url $RPC
    //   -> ~1.060e18  (1 weETH is worth ~1.060 eETH/ETH at block 22 000 000)
    //
    // RATE AT YIELD_BLOCK
    //   cast call 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee \
    //     "getEETHByWeETH(uint256)(uint256)" 1000000000000000000 \
    //     --block 23000000 --rpc-url $RPC
    //   -> ~1.067e18  (rate increases as ether.fi validators earn further rewards)
    //
    // YIELD ADVANCE STRATEGY: same deal-extra-tokens approach as wstETH (see above).
    //
    // REDEEM (inverse of mint)
    //   rate > 1, so 1 esETH redeems LESS than 1 weETH.
    //   E.g. at rate 1.060: redeeming 1e18 esETH gives ~0.943 weETH back.

    function testFork_WeETH() public {
        address user = makeAddr("weeth_user");
        uint256 depositAmt = 2e18;

        // --- 1. Rate at FORK_BLOCK ---
        uint256 rate1e18 = IWeETH(WEETH).getEETHByWeETH(1e18);
        assertGt(rate1e18, 1e18,   "weETH: getEETHByWeETH(1e18) must be > 1e18 at fork block");
        assertLt(rate1e18, 1.5e18, "weETH: getEETHByWeETH sanity upper bound");
        console2.log("weETH getEETHByWeETH(1e18) at FORK_BLOCK:", rate1e18);

        // --- 2. Mint: esETH = getEETHByWeETH(depositAmt) ---
        uint256 minted = _mintEsETH(WEETH, user, depositAmt);
        assertEq(minted, IWeETH(WEETH).getEETHByWeETH(depositAmt),
            "weETH: minted esETH must equal getEETHByWeETH(depositAmt)");
        assertGt(minted, depositAmt,
            "weETH: minted esETH > deposited tokens because rate > 1");

        // --- 3. Yield advance: deal ~5% extra weETH to simulate oracle rate increase ---
        uint256 extraTokens = depositAmt / 20;
        deal(WEETH, address(esETHContract),
            IERC20(WEETH).balanceOf(address(esETHContract)) + extraTokens);

        // --- 4. Harvest ---
        // harvestYield computes getEETHByWeETH(totalBalance) - totalMinted.
        // Because extra tokens were added at the same rate, yield = getEETHByWeETH(extraTokens).
        uint256 expectedYield = IWeETH(WEETH).getEETHByWeETH(extraTokens);
        _harvest(WEETH);
        assertEq(esETHContract.balanceOf(owner), expectedYield,
            "weETH: harvestYield must mint exactly the esETH-valued surplus");

        // --- 5. Redeem: fewer weETH returned than deposited (rate > 1) ---
        uint256 redeemAmt    = (minted / 2 - 1) * 1e18 / rate1e18;
        uint256 redeemValue  = IWeETH(WEETH).getEETHByWeETH(redeemAmt);
        uint256 expectedBurn = redeemValue + 1;
        assertLe(expectedBurn, esETHContract.balanceOf(user), "sanity: user has enough esETH");
        assertLt(redeemAmt, depositAmt / 2,
            "weETH: weETH returned is less than half the deposit (rate > 1)");

        vm.prank(user);
        uint256 burned = esETHContract.redeem(WEETH, redeemAmt, user);

        assertEq(burned, expectedBurn,
            "weETH: esETH burned must equal getEETHByWeETH(redeemAmt) + 1");
        assertEq(IERC20(WEETH).balanceOf(user), redeemAmt,
            "weETH: user receives the exact requested weETH amount");

        console2.log("weETH minted esETH:  ", minted, "| deposited weETH:", depositAmt);
        console2.log("weETH yield harvested:", expectedYield);
        console2.log("weETH redeemed:       ", redeemAmt, "| esETH burned:", burned);
    }

}
