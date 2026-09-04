// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {EthStrategyPerpetualNote} from "src/EthStrategyPerpetualNote.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";
import {IMerklDistributionCreator} from "./interfaces/IMerklDistributionCreator.sol";
import {MerklCampaignLib} from "./MerklCampaignLib.sol";

/// @notice Repeatable, manually triggered -- NOT one-time automation. No cron, keeper, or CI
/// schedule. Amount per run comes from env WEEKLY_YIELD_AMOUNT (plain decimal wei) and the start
/// from env WEEKLY_YIELD_START (hour-aligned unix seconds), not settings.json, because both
/// change every run.
///
/// Never broadcasts: the payer is the redemption Safe. Each run emits a Safe Transaction Builder
/// batch -- USDS.approve(DistributionCreator, amount), acceptConditions() only when the live
/// check demands it, DistributionCreator.createCampaign(params) -- creating a NEW 7-day Merkl
/// campaign that pays USDS to plain STRY holders. There is no staking contract: holders do
/// nothing but hold STRY, Merkl time-weights their balances off-chain, and they self-claim on
/// Merkl's Distributor.
///
/// createCampaign is idempotent per (creator, rewardToken, type, start, duration, campaignData)
/// and reverts CampaignAlreadyExists on an exact duplicate, so an accidentally re-imported batch
/// fails rather than double-paying.
contract WeeklyYield is Script {
    uint256 internal constant BASE_9 = 1e9;

    function run() external virtual {
        address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        address usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
        address stry = ConfigLib.addr("deploymentAddresses.json", ".stry");
        address dc = ConfigLib.addr("externalAddresses.json", ".merkl.distributionCreator");
        address[] memory blacklist = ConfigLib.addrArray("settings.json", ".espnv3.merkl.blacklist");
        uint256 amount = vm.envUint("WEEKLY_YIELD_AMOUNT");
        uint32 startTimestamp = uint32(vm.envUint("WEEKLY_YIELD_START"));

        (IMerklDistributionCreator.CampaignParameters memory params,, string memory json) =
            weeklyYield(safe, usds, stry, amount, startTimestamp, blacklist);

        // Store the canonical config with Merkl BEFORE writing the batch. The engine resolves
        // campaignData by looking the hash up in its config store, so an unstored hash is a
        // campaign it can never score. Storing is idempotent and has no on-chain effect, so
        // re-running this script is harmless; a network failure yields no batch at all rather
        // than an un-scoreable one.
        _storeConfig(json, params.campaignData);

        SafeBatchLib.Tx[] memory txs = _batch(dc, usds, safe, amount, params);
        SafeBatchLib.write(
            safe,
            "004-stry-migration",
            _firstFreeBatchIndex(safe),
            "Weekly STRY yield via Merkl",
            "Creates a new 7-day Merkl ERC20LOGPROCESSOR campaign paying USDS to STRY holders. Execute the transactions in the order listed.",
            txs
        );
    }

    /// @dev Pure computation plus live pre-condition reads. Writes no file and never calls
    /// vm.ffi -- run() alone does both -- so `yarn verify:migration`, which calls this directly,
    /// leaves `git status` clean.
    function weeklyYield(
        address safe,
        address usds,
        address stry,
        uint256 amount,
        uint32 startTimestamp,
        address[] memory blacklist
    )
        internal
        view
        returns (IMerklDistributionCreator.CampaignParameters memory params, bytes32 campaignId, string memory json)
    {
        IMerklDistributionCreator dc =
            IMerklDistributionCreator(ConfigLib.addr("externalAddresses.json", ".merkl.distributionCreator"));
        uint32 campaignType = uint32(ConfigLib.num("settings.json", ".espnv3.merkl.campaignType"));
        uint32 duration = uint32(ConfigLib.num("settings.json", ".espnv3.merkl.duration"));

        _merklPreconditions(dc, safe, usds, stry, amount, startTimestamp, duration);

        json = MerklCampaignLib.canonicalJson({
            amount: amount,
            creator: safe,
            rewardToken: usds,
            targetToken: stry,
            campaignType: campaignType,
            startTimestamp: startTimestamp,
            duration: duration,
            blacklist: blacklist,
            url: ""
        });

        params = IMerklDistributionCreator.CampaignParameters({
            campaignId: bytes32(0),
            creator: safe, // explicit, not address(0): campaignId hashes the creator field
            rewardToken: usds,
            amount: amount,
            campaignType: campaignType,
            startTimestamp: startTimestamp,
            duration: duration,
            campaignData: abi.encodePacked(MerklCampaignLib.campaignData(json))
        });
        campaignId = dc.campaignId(params);
        // campaignId is not one of the fields campaignId() hashes, so filling it in afterwards
        // does not change the id -- it just makes the batch's calldata self-describing and lets
        // Verify compare campaign(id) against params field for field.
        params.campaignId = campaignId;

        // campaignLookup REVERTS CampaignDoesNotExist() for an unknown id -- it does not return 0
        // (confirmed live on mainnet). So the duplicate guard is "did the lookup succeed", not a
        // value comparison. try/catch is legal from an internal view function.
        try dc.campaignLookup(campaignId) returns (uint256) {
            revert(
                "WeeklyYield: a campaign with these exact parameters already exists -- change WEEKLY_YIELD_START or WEEKLY_YIELD_AMOUNT"
            );
        } catch {}

        _log(dc, params, json);
    }

    /// @dev acceptConditions() is per creator address and permanent for the current messageHash.
    /// The redemption Safe is on userSignatureWhitelist today, so the emitted batch has two
    /// transactions; the branch exists so a change of creator Safe, or a Merkl messageHash
    /// rotation, still produces a batch that executes.
    function _needsAcceptConditions(IMerklDistributionCreator dc, address safe) internal view returns (bool) {
        return dc.userSignatureWhitelist(safe) == 0 && dc.userSignatures(safe) != dc.messageHash();
    }

    /// @dev Mirrors DistributionCreator._computeFees exactly. campaignSpecificFees == 1 means
    /// zero fees; == 0 means the default applies. Mainnet today: campaignSpecificFees(18) == 0,
    /// defaultFees == 3e7 of BASE_9 == 3%, feeRebate(redemption Safe) == 0.
    function _merklFeeSplit(IMerklDistributionCreator dc, address creator, uint32 campaignType, uint256 amount)
        internal
        view
        returns (uint256 net, uint256 fee)
    {
        uint256 base = dc.campaignSpecificFees(campaignType);
        if (base == 1) base = 0;
        else if (base == 0) base = dc.defaultFees();
        uint256 fees = base * (BASE_9 - dc.feeRebate(creator)) / BASE_9;
        net = amount * (BASE_9 - fees) / BASE_9;
        fee = amount - net;
    }

    function _merklPreconditions(
        IMerklDistributionCreator dc,
        address safe,
        address usds,
        address stry,
        uint256 amount,
        uint32 startTimestamp,
        uint32 duration
    ) internal view {
        // Carried over from StopEspnYield/BuildOrder: the only cheap on-chain proof the
        // hand-copied USDS address is right.
        address espnAddr = ConfigLib.addr("externalAddresses.json", ".eth-strategy.espn");
        require(EthStrategyPerpetualNote(espnAddr).asset() == usds, "WeeklyYield: ESPN.asset() != USDS");

        // Same idea for the two Merkl addresses: prove they relate to each other on-chain.
        require(address(dc).code.length > 0, "WeeklyYield: .merkl.distributionCreator has no code");
        require(
            dc.distributor() == ConfigLib.addr("externalAddresses.json", ".merkl.distributor"),
            "WeeklyYield: .merkl.distributor != DistributionCreator.distributor()"
        );

        // A campaign targeting an undeployed or undistributed token is accepted by the contract
        // and pays nobody.
        require(stry.code.length > 0, "WeeklyYield: STRY has no code -- run Distribute.s.sol first");
        require(
            IERC20(stry).totalSupply() > 0,
            "WeeklyYield: STRY totalSupply() == 0 -- a campaign targeting an undistributed token pays nobody"
        );

        // Mirrors _createCampaign so the failure names the floor instead of a bare
        // CampaignRewardTooLow.
        uint256 minAmount = dc.rewardTokenMinAmounts(usds);
        require(minAmount != 0, "WeeklyYield: USDS is not whitelisted as a Merkl reward token");
        require(
            amount * 3600 >= minAmount * duration,
            "WeeklyYield: WEEKLY_YIELD_AMOUNT is below Merkl's floor of rewardTokenMinAmounts(USDS) per campaign-hour (>= 168 USDS for a 7-day campaign)"
        );

        require(IERC20(usds).balanceOf(safe) >= amount, "WeeklyYield: Safe USDS balance < WEEKLY_YIELD_AMOUNT");

        // The Safe executes hours or days after this script runs and the contract does not check
        // start against the clock, so a stale start silently produces a campaign that is already
        // partly elapsed when funded. Same forcing-function pattern as orderStartTime.
        require(
            startTimestamp > block.timestamp + 1 days,
            "WeeklyYield: WEEKLY_YIELD_START must be more than 1 day ahead -- the Safe executes hours or days after this script runs"
        );
        require(startTimestamp % 3600 == 0, "WeeklyYield: WEEKLY_YIELD_START must be hour-aligned (start % 3600 == 0)");
    }

    /// @dev Everything the Safe signer needs to check before signing, including the URL that
    /// proves Merkl already holds the config this campaignData resolves to.
    function _log(
        IMerklDistributionCreator dc,
        IMerklDistributionCreator.CampaignParameters memory params,
        string memory json
    ) internal view {
        (uint256 net, uint256 fee) = _merklFeeSplit(dc, params.creator, params.campaignType, params.amount);
        console2.log("gross USDS pulled from the Safe:", params.amount);
        console2.log("Merkl fee:", fee);
        console2.log("net to Merkl Distributor:", net);
        console2.log("campaignId:");
        console2.logBytes32(params.campaignId);
        console2.log("campaignData (sha256 of the canonical config JSON):");
        console2.log(vm.toString(params.campaignData));
        console2.log("canonical config JSON (this is what run() POSTs to Merkl's config store):");
        console2.log(json);
        console2.log(string.concat("campaign start: ", MerklCampaignLib.isoUtc(params.startTimestamp)));
        console2.log(
            string.concat("campaign end:   ", MerklCampaignLib.isoUtc(uint256(params.startTimestamp) + params.duration))
        );
        console2.log("SIGNER CHECK -- Merkl must already hold this config before you sign:");
        console2.log(string.concat("https://api.merkl.xyz/v4/config/hash/", vm.toString(params.campaignData)));
    }

    /// @dev Transactions in fixed execution order. The approval is for the exact amount, not
    /// type(uint256).max: the allowance is consumed in the same execution (_pullTokens does one
    /// safeTransferFrom for the net leg and one for the fee leg, both from the Safe) and nothing
    /// should be left standing -- same reasoning as Cancel.s.sol's revoke.
    function _batch(
        address dc,
        address usds,
        address safe,
        uint256 amount,
        IMerklDistributionCreator.CampaignParameters memory params
    ) internal view returns (SafeBatchLib.Tx[] memory txs) {
        bool needsAccept = _needsAcceptConditions(IMerklDistributionCreator(dc), safe);
        txs = new SafeBatchLib.Tx[](needsAccept ? 3 : 2);
        txs[0] = SafeBatchLib.Tx({to: usds, data: abi.encodeCall(IERC20.approve, (dc, amount))});
        uint256 i = 1;
        if (needsAccept) {
            txs[i++] = SafeBatchLib.Tx({to: dc, data: abi.encodeCall(IMerklDistributionCreator.acceptConditions, ())});
        }
        txs[i] = SafeBatchLib.Tx({to: dc, data: abi.encodeCall(IMerklDistributionCreator.createCampaign, (params))});
        console2.log("Safe batch transaction count (3 means acceptConditions() is included):", txs.length);
    }

    /// @dev The one off-chain call, and it lives in run() only -- never in weeklyYield(), which
    /// Verify.s.sol calls. ffi = true is already global in foundry.toml. The response is asserted
    /// against the locally computed hash, so a compromised response cannot alter the batch.
    function _storeConfig(string memory json, bytes memory expectedHash) internal {
        string[] memory curl = new string[](9);
        curl[0] = "curl";
        curl[1] = "-sS";
        curl[2] = "-X";
        curl[3] = "POST";
        curl[4] = "https://api.merkl.xyz/v4/config/store";
        curl[5] = "-H";
        curl[6] = "content-type: application/json";
        curl[7] = "--data";
        curl[8] = json;

        bytes memory response = vm.ffi(curl);
        console2.log("POST https://api.merkl.xyz/v4/config/store returned:");
        console2.log(vm.toString(response));
        // forge decodes an ffi stdout that looks like 0x-prefixed hex into raw bytes and returns
        // anything else verbatim, so accept either encoding of the same hash.
        require(
            keccak256(response) == keccak256(expectedHash)
                || keccak256(response) == keccak256(bytes(vm.toString(expectedHash))),
            "WeeklyYield: Merkl config/store did not return the locally computed campaignData hash"
        );
    }

    /// @dev This is the repo's first repeatable batch producer, and SafeBatchLib.write ends in
    /// vm.writeFile, which overwrites silently. A stale index would rewrite a previous week's
    /// batch in place with a different campaignData and amount, with no error -- and a batch
    /// mid-signature-collection in the Safe UI would stop matching what the next signer diffs
    /// against. So there is no index env var and no manual counter: 001 is taken by
    /// StopEspnYield.s.sol, so start at 2 and take the first free index. Redoing a week whose
    /// batch was generated but not signed means deleting that file first -- a deliberate act on
    /// a named path.
    function _firstFreeBatchIndex(address safe) internal view returns (uint256 index) {
        for (index = 2;; ++index) {
            if (!vm.exists(SafeBatchLib.path(safe, "004-stry-migration", index))) return index;
        }
    }
}
