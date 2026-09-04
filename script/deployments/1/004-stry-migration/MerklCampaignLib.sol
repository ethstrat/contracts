// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Pure canonical-JSON + sha256 encoder for Merkl's `campaignData`, plus the ISO-8601
/// window rendering WeeklyYield.s.sol logs for the Safe signers.
///
/// On the current Merkl engine `campaignData` is NOT an ABI-encoded config: it is
/// sha256(canonicalJson(config)), and the JSON itself must be stored with Merkl
/// (POST https://api.merkl.xyz/v4/config/store) so the engine can resolve the hash. Canonical
/// form = keys in sorted order, no whitespace, addresses EIP-55 checksummed (exactly what
/// vm.toString(address) emits), the amount as a decimal string, timestamps as JSON numbers.
///
/// Verified: this string's sha256 reproduces the on-chain campaignData of the treasury's own
/// Feb-2026 campaign 0x2653bced... -- see test/unit/MerklCampaignLibTest.sol. Reads no config
/// and touches no chain state.
library MerklCampaignLib {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @param url Merkl campaign page URL, emitted in sorted position between `targetToken` and
    /// `whitelist`. "" omits the key entirely, which is what production passes -- the key is
    /// optional in Merkl's schema and there is no STRY page. The argument exists because the
    /// Feb-2026 fixture the unit test pins does carry a url inside the hashed string, so a
    /// library that could never emit `url` could not reproduce that hash at all.
    /// @dev computeChainId is the literal 1: every script under script/deployments/1/ is
    /// mainnet-only.
    function canonicalJson(
        uint256 amount,
        address creator,
        address rewardToken,
        address targetToken,
        uint32 campaignType,
        uint32 startTimestamp,
        uint32 duration,
        address[] memory blacklist,
        string memory url
    ) internal pure returns (string memory) {
        // Split in two so the concat argument list stays readable; the halves are joined below.
        string memory head = string.concat(
            "{\"amount\":\"",
            vm.toString(amount),
            "\",\"blacklist\":",
            _addressArray(blacklist),
            ",\"campaignType\":",
            vm.toString(uint256(campaignType)),
            ",\"computeChainId\":1,\"computeScoreParameters\":{\"computeMethod\":\"genericTimeWeighted\"},\"creator\":\"",
            vm.toString(creator),
            "\",\"distributionMethodParameters\":{\"distributionMethod\":\"DUTCH_AUCTION\",\"distributionSettings\":{}},\"endTimestamp\":",
            vm.toString(uint256(startTimestamp) + duration)
        );
        return string.concat(
            head,
            ",\"forwarders\":[],\"hooks\":[],\"rewardToken\":\"",
            vm.toString(rewardToken),
            "\",\"startTimestamp\":",
            vm.toString(uint256(startTimestamp)),
            ",\"targetToken\":\"",
            vm.toString(targetToken),
            "\",",
            _urlKey(url),
            "\"whitelist\":[]}"
        );
    }

    /// @dev The on-chain campaignData, as 32 bytes. Takes the JSON rather than repeating
    /// canonicalJson's nine arguments: it is sha256 and nothing else, and one argument list per
    /// call site is one place a transposed address can hide instead of two.
    function campaignData(string memory json) internal pure returns (bytes32) {
        return sha256(bytes(json));
    }

    /// @dev Unix seconds -> "YYYY-MM-DDTHH:MM:SSZ" (Howard Hinnant's civil-from-days algorithm).
    /// Logged for the Safe signers so the campaign window is readable without a converter.
    function isoUtc(uint256 unixSeconds) internal pure returns (string memory) {
        uint256 z = unixSeconds / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) ++y;
        uint256 s = unixSeconds % 86400;
        return string.concat(
            vm.toString(y),
            "-",
            _two(m),
            "-",
            _two(d),
            "T",
            _two(s / 3600),
            ":",
            _two((s % 3600) / 60),
            ":",
            _two(s % 60),
            "Z"
        );
    }

    function _addressArray(address[] memory addrs) private pure returns (string memory out) {
        out = "[";
        for (uint256 i; i < addrs.length; ++i) {
            out = string.concat(out, i == 0 ? "\"" : ",\"", vm.toString(addrs[i]), "\"");
        }
        out = string.concat(out, "]");
    }

    function _urlKey(string memory url) private pure returns (string memory) {
        if (bytes(url).length == 0) return "";
        return string.concat("\"url\":\"", url, "\",");
    }

    function _two(uint256 v) private pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }
}
