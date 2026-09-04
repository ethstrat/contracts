// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MerklCampaignLib} from "../../script/deployments/1/004-stry-migration/MerklCampaignLib.sol";

/// @notice Pins the canonicalisation against a real mainnet campaign, no fork needed: the
/// treasury's own Feb-2026 wETH -> sSTRAT campaign
/// 0x2653bceda930d0c6f409bc8744ab04c19a71b8ea55f73d498b6667032ccc3cb0, created from the main
/// Safe. Its on-chain campaignData is 0x687bd056...;
/// GET https://api.merkl.xyz/v4/config/hash/0x687bd056... returns the stored JSON, and sha256 of
/// that JSON re-serialised with sorted keys and no whitespace equals it.
contract MerklCampaignLibTest is Test {
    uint256 internal constant FIXTURE_AMOUNT = 23_200_000_000_000_000_000; // 23.2 wETH
    address internal constant MAIN_SAFE = 0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant SSTRAT = 0xD6664390E0485Cd609d4D04b430e84e945a51994;
    address internal constant REDEMPTION_SAFE = 0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D;
    uint32 internal constant FIXTURE_START = 1_771_160_400; // 2026-02-15T13:00:00Z
    uint32 internal constant FIXTURE_DURATION = 3_628_800; // 42 days -> end 1774789200
    string internal constant FIXTURE_URL = "https://app.ethstrat.xyz/strat";

    bytes32 internal constant FIXTURE_HASH_WITH_URL =
        0x687bd05668bd74bd5b5bc83cd6c516f3a4cf32c991735da35670990e16f4d706;
    bytes32 internal constant FIXTURE_HASH_NO_URL = 0x4e08c911037453c7e092198804fbbcfd7cfd01f0cb3b0ffa53eab0b19141c6b1;
    bytes32 internal constant FIXTURE_HASH_TWO_BLACKLISTED =
        0x8c15ee7c2623732b0ce1030ac5e3f57a7ef4c9f573e811a8fad92477c79a5409;

    function _fixtureJson(uint256 amount, address[] memory blacklist, string memory url)
        internal
        pure
        returns (string memory)
    {
        return MerklCampaignLib.canonicalJson({
            amount: amount,
            creator: MAIN_SAFE,
            rewardToken: WETH,
            targetToken: SSTRAT,
            campaignType: 18,
            startTimestamp: FIXTURE_START,
            duration: FIXTURE_DURATION,
            blacklist: blacklist,
            url: url
        });
    }

    /// @dev The mainnet-anchored assertion. It covers key ordering, the number-vs-string choice
    /// per key, and -- the likeliest thing to go wrong -- whether vm.toString(address) emits the
    /// EIP-55 checksum casing the stored JSON uses. If this fails on casing, the library needs a
    /// checksum routine.
    function test_campaignData_matchesMainnetFixture_withUrl() public pure {
        assertEq(
            MerklCampaignLib.campaignData(_fixtureJson(FIXTURE_AMOUNT, new address[](0), FIXTURE_URL)),
            FIXTURE_HASH_WITH_URL,
            "canonical JSON with url does not hash to campaign 0x2653bced...'s on-chain campaignData"
        );
    }

    /// @dev The omission branch: the shape production actually hashes and Merkl must store.
    function test_campaignData_matchesMainnetFixture_withoutUrl() public pure {
        assertEq(
            MerklCampaignLib.campaignData(_fixtureJson(FIXTURE_AMOUNT, new address[](0), "")),
            FIXTURE_HASH_NO_URL,
            "canonical JSON without url does not hash to the pinned value"
        );
    }

    /// @dev Pins the string itself, so a canonicalisation failure names the offending character
    /// instead of only a mismatched 32-byte hash.
    function test_canonicalJson_exactStoredString() public pure {
        assertEq(
            _fixtureJson(FIXTURE_AMOUNT, new address[](0), FIXTURE_URL),
            "{\"amount\":\"23200000000000000000\",\"blacklist\":[],\"campaignType\":18,\"computeChainId\":1,\"computeScoreParameters\":{\"computeMethod\":\"genericTimeWeighted\"},\"creator\":\"0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8\",\"distributionMethodParameters\":{\"distributionMethod\":\"DUTCH_AUCTION\",\"distributionSettings\":{}},\"endTimestamp\":1774789200,\"forwarders\":[],\"hooks\":[],\"rewardToken\":\"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"startTimestamp\":1771160400,\"targetToken\":\"0xD6664390E0485Cd609d4D04b430e84e945a51994\",\"url\":\"https://app.ethstrat.xyz/strat\",\"whitelist\":[]}",
            "canonical JSON string drifted from the config Merkl stores for campaign 0x2653bced..."
        );
    }

    function test_canonicalJson_blacklistSerialisation() public pure {
        address[] memory two = new address[](2);
        two[0] = REDEMPTION_SAFE;
        two[1] = SSTRAT;

        assertEq(
            _fixtureJson(FIXTURE_AMOUNT, two, ""),
            "{\"amount\":\"23200000000000000000\",\"blacklist\":[\"0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D\",\"0xD6664390E0485Cd609d4D04b430e84e945a51994\"],\"campaignType\":18,\"computeChainId\":1,\"computeScoreParameters\":{\"computeMethod\":\"genericTimeWeighted\"},\"creator\":\"0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8\",\"distributionMethodParameters\":{\"distributionMethod\":\"DUTCH_AUCTION\",\"distributionSettings\":{}},\"endTimestamp\":1774789200,\"forwarders\":[],\"hooks\":[],\"rewardToken\":\"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"startTimestamp\":1771160400,\"targetToken\":\"0xD6664390E0485Cd609d4D04b430e84e945a51994\",\"whitelist\":[]}",
            "non-empty blacklist is not serialised as a JSON array of checksummed addresses"
        );
        assertEq(
            MerklCampaignLib.campaignData(_fixtureJson(FIXTURE_AMOUNT, two, "")),
            FIXTURE_HASH_TWO_BLACKLISTED,
            "two-address blacklist hash drifted"
        );
    }

    function test_campaignData_amountSensitivity() public pure {
        assertTrue(
            MerklCampaignLib.campaignData(_fixtureJson(FIXTURE_AMOUNT, new address[](0), ""))
                != MerklCampaignLib.campaignData(_fixtureJson(FIXTURE_AMOUNT + 1, new address[](0), "")),
            "two configs differing only in amount hash identically"
        );
    }

    /// @dev isoUtc is what WeeklyYield.s.sol prints for the Safe signers. Pinned against the same
    /// fixture window so the date arithmetic has a runnable check.
    function test_isoUtc_pinsFixtureWindow() public pure {
        assertEq(MerklCampaignLib.isoUtc(FIXTURE_START), "2026-02-15T13:00:00Z");
        assertEq(MerklCampaignLib.isoUtc(uint256(FIXTURE_START) + FIXTURE_DURATION), "2026-03-29T13:00:00Z");
    }
}
