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
import {WeeklyYieldProbe} from "./WeeklyYieldProbe.s.sol";

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

        // Items 4-6, 10: split into a helper -- via-ir hits "stack too deep" when this many
        // locals (items 0-3's plus these) are live in one function body.
        _executeAndVerifyCampaign(dc, safe, usds, params, campaignId, start);

        // Items 7-9: the negative paths.
        _assertRejectsBelowMinimum(dc, safe, usds, address(stry), start, blacklist);
        _assertRejectsDuplicate(dc, safe, usds, params);
        _assertUnsignedCreatorMustAcceptConditions(dc, usds, params);
    }

    /// @dev Items 4-6, 10. Execute the batch's calls in the emitted order, as the Safe.
    /// startPrank's two-argument form also sets tx.origin, because Merkl's hasSigned modifier
    /// reads both.
    function _executeAndVerifyCampaign(
        IMerklDistributionCreator dc,
        address safe,
        address usds,
        IMerklDistributionCreator.CampaignParameters memory params,
        bytes32 campaignId,
        uint32 start
    ) internal {
        {
            (uint256 net, uint256 fee) = _merklFeeSplit(dc, safe, params.campaignType, params.amount);
            // The Safe holds ~1.2M USDS on this fork, so assert the real balance rather than
            // faking it; deal only if a future fork block is short.
            if (IERC20(usds).balanceOf(safe) < params.amount) {
                console2.log("WARNING: fork Safe USDS balance short -- dealing instead of using the real balance");
                deal(usds, safe, params.amount);
            }
            address distributorAddr = dc.distributor();
            address feeRecipientAddr = dc.feeRecipient();
            uint256 safeBefore = IERC20(usds).balanceOf(safe);
            uint256 distributorBefore = IERC20(usds).balanceOf(distributorAddr);
            uint256 feeRecipientBefore = IERC20(usds).balanceOf(feeRecipientAddr);

            // The script omits acceptConditions() from the batch when the Safe is whitelisted.
            // Assert the branch agrees with the live state rather than trusting either alone.
            assertEq(dc.userSignatureWhitelist(safe), 1, "Verify: redemption Safe is no longer Merkl-whitelisted");
            assertFalse(
                _needsAcceptConditions(dc, safe),
                "Verify: script would include acceptConditions() for a whitelisted Safe"
            );

            vm.startPrank(safe, safe);
            IERC20(usds).approve(address(dc), params.amount);
            uint256 gasBefore = gasleft();
            bytes32 createdId = dc.createCampaign(params);
            uint256 executionGas = gasBefore - gasleft();
            vm.stopPrank();

            assertEq(createdId, campaignId, "Verify: createCampaign returned a different id than campaignId()");

            // Item 5: registration. campaignLookup reverts CampaignDoesNotExist() for an unknown
            // id and returns index-1 otherwise, so "registered" means "this call does not revert".
            try dc.campaignLookup(createdId) returns (uint256) {}
            catch {
                revert("Verify: campaign is not registered");
            }
            IMerklDistributionCreator.CampaignParameters memory stored = dc.campaign(createdId);
            assertEq(stored.campaignId, campaignId, "Verify: stored campaignId mismatch");
            assertEq(stored.creator, safe, "Verify: stored creator != the redemption Safe");
            assertEq(stored.rewardToken, usds, "Verify: stored rewardToken != USDS");
            assertEq(uint256(stored.campaignType), 18, "Verify: stored campaignType != 18");
            assertEq(uint256(stored.startTimestamp), uint256(start), "Verify: stored startTimestamp mismatch");
            assertEq(uint256(stored.duration), 604_800, "Verify: stored duration != 604800");
            assertEq(stored.campaignData, params.campaignData, "Verify: stored campaignData mismatch");
            // DistributionCreator stores the amount NET of fees -- confirmed on mainnet against
            // the treasury's own campaign (23.2 -> 22.504 wETH at the default 3%).
            assertEq(stored.amount, net, "Verify: stored amount != gross * (1e9 - fees) / 1e9");

            // Item 6: balances.
            assertEq(IERC20(usds).balanceOf(safe), safeBefore - params.amount, "Verify: Safe USDS delta != -gross");
            assertEq(
                IERC20(usds).balanceOf(distributorAddr),
                distributorBefore + net,
                "Verify: Distributor USDS delta != +net"
            );
            assertEq(
                IERC20(usds).balanceOf(feeRecipientAddr),
                feeRecipientBefore + fee,
                "Verify: feeRecipient USDS delta != +fee"
            );
            assertEq(
                IERC20(usds).allowance(safe, address(dc)),
                0,
                "Verify: USDS allowance to DistributionCreator not fully consumed"
            );

            // Item 10: gas, in the Step 23 two-line format. The calldata term is an upper bound
            // (16 gas per byte, ignoring the 4-gas discount on zero bytes).
            uint256 calldataGasEstimate =
                21_000 + abi.encodeCall(IMerklDistributionCreator.createCampaign, (params)).length * 16;
            console2.log("createCampaign execution gas:", executionGas);
            console2.log(
                "createCampaign total estimated (execution + 21000 intrinsic + calldata):",
                executionGas + calldataGasEstimate
            );
        }
    }

    /// @dev Item 7. Both halves of the same floor: Merkl's own revert, and the script's named
    /// pre-condition, which exists so the operator sees the 168 USDS figure instead of a bare
    /// CampaignRewardTooLow.
    function _assertRejectsBelowMinimum(
        IMerklDistributionCreator dc,
        address safe,
        address usds,
        address stry,
        uint32 start,
        address[] memory blacklist
    ) internal {
        uint256 tooLow = dc.rewardTokenMinAmounts(usds) * 168 - 1;

        // A different start keeps the campaignId distinct from the one already created, so this
        // reverts on the amount and not on CampaignAlreadyExists.
        IMerklDistributionCreator.CampaignParameters memory low = IMerklDistributionCreator.CampaignParameters({
            campaignId: bytes32(0),
            creator: safe,
            rewardToken: usds,
            amount: tooLow,
            campaignType: 18,
            startTimestamp: start + 3600,
            duration: 604_800,
            campaignData: abi.encodePacked(
                MerklCampaignLib.campaignData(
                    MerklCampaignLib.canonicalJson({
                        amount: tooLow,
                        creator: safe,
                        rewardToken: usds,
                        targetToken: stry,
                        campaignType: 18,
                        startTimestamp: start + 3600,
                        duration: 604_800,
                        blacklist: blacklist,
                        url: ""
                    })
                )
            )
        });

        vm.startPrank(safe, safe);
        IERC20(usds).approve(address(dc), tooLow);
        vm.expectRevert(IMerklDistributionCreator.CampaignRewardTooLow.selector);
        dc.createCampaign(low);
        IERC20(usds).approve(address(dc), 0);
        vm.stopPrank();

        // The script's own pre-condition, asserted through an external call boundary --
        // weeklyYield is an internal function, so vm.expectRevert cannot observe its revert
        // otherwise (same reason as ScriptLibsTest._loadExternal). Unlike that Test contract,
        // Verify is a Script: forge script blocks a self-call via `this.foo()` ("Usage of
        // `address(this)` detected in script contract"), so the wrapper lives on a separate
        // deployed WeeklyYieldProbe instance instead of address(this). The deploy happens before
        // expectRevert is armed -- expectRevert binds to the very next call, and a `new` in the
        // same statement would bind it to the CREATE instead of the external call that reverts.
        WeeklyYieldProbe probe = new WeeklyYieldProbe();
        vm.expectRevert(
            bytes(
                "WeeklyYield: WEEKLY_YIELD_AMOUNT is below Merkl's floor of rewardTokenMinAmounts(USDS) per campaign-hour (>= 168 USDS for a 7-day campaign)"
            )
        );
        probe.weeklyYieldExternal(safe, usds, stry, tooLow, start + 3600, blacklist);
    }

    /// @dev Item 8. _createCampaign pulls the tokens before it checks the id, so the allowance
    /// has to be re-granted for the attempt even though it reverts and rolls back.
    function _assertRejectsDuplicate(
        IMerklDistributionCreator dc,
        address safe,
        address usds,
        IMerklDistributionCreator.CampaignParameters memory params
    ) internal {
        if (IERC20(usds).balanceOf(safe) < params.amount) deal(usds, safe, params.amount);
        vm.startPrank(safe, safe);
        IERC20(usds).approve(address(dc), params.amount);
        vm.expectRevert(IMerklDistributionCreator.CampaignAlreadyExists.selector);
        dc.createCampaign(params);
        IERC20(usds).approve(address(dc), 0);
        vm.stopPrank();
    }

    /// @dev Item 9. Proves the conditional second transaction is the right shape for a Safe that
    /// is not on userSignatureWhitelist: createCampaign reverts NotSigned, acceptConditions()
    /// fixes it, the identical call then succeeds. campaignData is deliberately left as the
    /// whitelisted Safe's -- the creator field alone makes the campaignId distinct, and on a
    /// fork there is no engine to resolve the config.
    function _assertUnsignedCreatorMustAcceptConditions(
        IMerklDistributionCreator dc,
        address usds,
        IMerklDistributionCreator.CampaignParameters memory params
    ) internal {
        address unsigned = makeAddr("unsignedCreator");
        assertEq(dc.userSignatureWhitelist(unsigned), 0, "Verify: the unsigned fixture address is whitelisted");
        deal(usds, unsigned, params.amount);

        IMerklDistributionCreator.CampaignParameters memory p = params;
        p.creator = unsigned;
        p.campaignId = bytes32(0);

        vm.startPrank(unsigned, unsigned);
        IERC20(usds).approve(address(dc), params.amount);
        vm.expectRevert(IMerklDistributionCreator.NotSigned.selector);
        dc.createCampaign(p);

        dc.acceptConditions();
        assertEq(dc.userSignatures(unsigned), dc.messageHash(), "Verify: acceptConditions did not record a signature");
        assertFalse(_needsAcceptConditions(dc, unsigned), "Verify: script would still ask a signed creator to sign");

        bytes32 unsignedId = dc.createCampaign(p);
        vm.stopPrank();
        // Same semantics as item 5: registration is proven by campaignLookup not reverting.
        try dc.campaignLookup(unsignedId) returns (uint256) {}
        catch {
            revert("Verify: campaign not registered after acceptConditions()");
        }
    }
}
