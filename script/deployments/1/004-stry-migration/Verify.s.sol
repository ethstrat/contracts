// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {EthStrategyPerpetualNote} from "src/EthStrategyPerpetualNote.sol";
import {StryToken} from "src/StryToken.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {HoldersLib} from "../lib/HoldersLib.sol";
import {IMerklDistributionCreator} from "./interfaces/IMerklDistributionCreator.sol";
import {MerklCampaignLib} from "./MerklCampaignLib.sol";
import {StopEspnYield} from "./StopEspnYield.s.sol";
import {Distribute} from "./Distribute.s.sol";
import {WeeklyYield} from "./WeeklyYield.s.sol";

/// @notice Track B mainnet-fork Verify script. Same harness as Track A: vm.startPrank, not
/// vm.startBroadcast, so no config or Safe batch file is written. Calls the other scripts'
/// internal entry points, never their run()s.
contract Verify is Script, StdCheats, StdAssertions, StopEspnYield, Distribute, WeeklyYield {
    /// @dev The fork Safe holds ~1.2M USDS, comfortably above this and above Merkl's 168 USDS
    /// floor for a 7-day campaign.
    uint256 internal constant FORK_YIELD_AMOUNT = 10_000e18;

    function run() external override(StopEspnYield, Distribute, WeeklyYield) {
        // Same derivation as 003-espn-redemption/Verify.s.sol: the holders file is named after the
        // snapshot block, so SNAPSHOT_BLOCK alone pins both the fork and the snapshot.
        uint256 snapshotBlockTarget = vm.envUint("SNAPSHOT_BLOCK");
        string memory holdersFile =
            string.concat("script/deployments/1/config/espn-holders-", vm.toString(snapshotBlockTarget), ".json");
        HoldersLib.Snapshot memory snapshot = HoldersLib.load(holdersFile);

        // Item 0: fork block check.
        require(block.number >= snapshot.snapshotBlock, "Verify: fork block is behind snapshotBlock");
        if (block.number != snapshot.snapshotBlock) {
            console2.log("WARNING: fork block != snapshotBlock; export SNAPSHOT_BLOCK to fix:");
            console2.log(snapshot.snapshotBlock);
        }

        // Item 1: StopEspnYield -- the third-party outflow must be visible in test output, not
        // merely pass.
        (address usds, address espnAddr, address payer, uint256 finalYieldAmount) = _preconditions();
        EthStrategyPerpetualNote espn = EthStrategyPerpetualNote(espnAddr);
        uint256 totalAssetsBefore = espn.totalAssets();
        uint256 managerBalanceBefore = IERC20(usds).balanceOf(espn.manager());
        if (IERC20(usds).balanceOf(payer) < finalYieldAmount) {
            deal(usds, payer, finalYieldAmount);
        }
        vm.startPrank(payer);
        IERC20(usds).approve(espnAddr, finalYieldAmount);
        vm.expectEmit(true, false, false, true, espnAddr);
        emit EthStrategyPerpetualNote.AssetsPerShareIncreased(
            payer, totalAssetsBefore + finalYieldAmount, finalYieldAmount
        );
        espn.increaseAssetsPerShare(finalYieldAmount);
        vm.stopPrank();
        assertEq(
            espn.totalAssets(), totalAssetsBefore + finalYieldAmount, "Verify: totalAssets delta != finalYieldAmount"
        );
        assertEq(
            IERC20(usds).balanceOf(espn.manager()),
            managerBalanceBefore + finalYieldAmount,
            "Verify: USDS did not land at ESPN.manager()"
        );

        // Item 2: Distribute STRY (single mintBatch). This is the fork-fresh STRY address item 3
        // passes to weeklyYield as an argument -- never via deploymentAddresses.json.
        address stryDeployer = makeAddr("stryDeployer");
        vm.startPrank(stryDeployer);
        StryToken stry = distribute(stryDeployer, holdersFile);
        vm.stopPrank();
        assertEq(stry.owner(), address(0), "Verify: STRY ownership not renounced");

        // Item 3: build the campaign. No vm.warp is needed: the start is derived from the fork
        // clock, 48 hour-slots ahead, which is >= block.timestamp + 47h and hour-aligned, so it
        // satisfies weeklyYield's two WEEKLY_YIELD_START pre-conditions by construction.
        address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        address[] memory blacklist = ConfigLib.addrArray("settings.json", ".espnv3.merkl.blacklist");
        uint32 start = uint32((block.timestamp / 3600 + 48) * 3600);

        (IMerklDistributionCreator.CampaignParameters memory params, bytes32 campaignId, string memory json) =
            weeklyYield(safe, usds, address(stry), FORK_YIELD_AMOUNT, start, blacklist);

        IMerklDistributionCreator dc =
            IMerklDistributionCreator(ConfigLib.addr("externalAddresses.json", ".merkl.distributionCreator"));
        assertEq(campaignId, dc.campaignId(params), "Verify: returned campaignId != DistributionCreator.campaignId");
        assertEq(
            params.campaignData,
            abi.encodePacked(MerklCampaignLib.campaignData(json)),
            "Verify: params.campaignData != sha256 of the JSON the script would POST to Merkl"
        );
        // Independent re-derivation from the same inputs, so a transposed argument inside
        // weeklyYield fails here rather than on Merkl's engine a week later.
        assertEq(
            json,
            MerklCampaignLib.canonicalJson({
                amount: FORK_YIELD_AMOUNT,
                creator: safe,
                rewardToken: usds,
                targetToken: address(stry),
                campaignType: params.campaignType,
                startTimestamp: start,
                duration: params.duration,
                blacklist: blacklist,
                url: ""
            }),
            "Verify: weeklyYield's canonical JSON does not match an independent re-derivation"
        );
        assertEq(uint256(params.campaignType), 18, "Verify: campaignType != 18 (ERC20LOGPROCESSOR)");
        assertEq(uint256(params.duration), 604_800, "Verify: duration != 604800 (7 days)");
        assertEq(params.creator, safe, "Verify: creator != the redemption Safe");
        assertEq(params.rewardToken, usds, "Verify: rewardToken != USDS");
        assertEq(params.amount, FORK_YIELD_AMOUNT, "Verify: amount != the requested gross");
        assertEq(params.campaignData.length, 32, "Verify: campaignData is not exactly 32 bytes");
    }
}
