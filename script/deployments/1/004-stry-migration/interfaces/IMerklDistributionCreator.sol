// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Merkl DistributionCreator interface -- only the surface 004-stry-migration
/// needs. Mainnet: 0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd (same address on most EVM chains).
/// The struct layout below was confirmed against mainnet: calling campaignId(...) with the
/// treasury's own Feb-2026 campaign fields returns that campaign's real id
/// 0x2653bceda930d0c6f409bc8744ab04c19a71b8ea55f73d498b6667032ccc3cb0.
interface IMerklDistributionCreator {
    // -------------------------------------------------------------------------
    // Errors asserted by Verify.s.sol
    // -------------------------------------------------------------------------

    error CampaignAlreadyExists();
    error CampaignRewardTokenNotWhitelisted();
    error CampaignRewardTooLow();
    error NotSigned();

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @dev `campaignId` is not one of the fields campaignId() hashes -- _createCampaign
    /// overwrites it with the derived id -- so filling it in before the call is cosmetic and
    /// does not change the resulting id.
    struct CampaignParameters {
        bytes32 campaignId;
        address creator;
        address rewardToken;
        uint256 amount;
        uint32 campaignType;
        uint32 startTimestamp;
        uint32 duration;
        bytes campaignData;
    }

    // -------------------------------------------------------------------------
    // State-changing
    // -------------------------------------------------------------------------

    function acceptConditions() external;

    function createCampaign(CampaignParameters memory newCampaign) external returns (bytes32);

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function campaignId(CampaignParameters memory campaign_) external view returns (bytes32);

    function campaign(bytes32 _campaignId) external view returns (CampaignParameters memory);

    /// @dev Reverts CampaignDoesNotExist() when the id is unknown; returns the campaign's
    /// index-1 otherwise. Confirmed live on mainnet. Existence is tested by the call not
    /// reverting -- never by comparing the return value against 0.
    function campaignLookup(bytes32 _campaignId) external view returns (uint256);

    function distributor() external view returns (address);

    function feeRecipient() external view returns (address);

    /// @dev Of BASE_9 = 1e9. Mainnet today: 30000000 == 3%.
    function defaultFees() external view returns (uint256);

    /// @dev 0 means "the default applies"; 1 means "zero fees".
    function campaignSpecificFees(uint32 campaignType) external view returns (uint256);

    function feeRebate(address user) external view returns (uint256);

    /// @dev 0 means the token is not whitelisted as an incentive token at all.
    function rewardTokenMinAmounts(address token) external view returns (uint256);

    function userSignatureWhitelist(address user) external view returns (uint256);

    function userSignatures(address user) external view returns (bytes32);

    function messageHash() external view returns (bytes32);
}
