// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StryToken} from "src/StryToken.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";

/// @notice One-off redemption-Safe batch: mints the EARN missed by 10 sESPN-LP stakers and direct
/// Arrakis ESPN/USDS vault holders, whose ESPN sat in the Uniswap V3 pool at the block 26043909
/// snapshot (V3 pools were not excluded from that snapshot, so their EARN went to the pool
/// contracts instead). Never broadcasts. Run with --fork-url mainnet: run() executes the exact
/// batch as the Safe on the latest-block fork and asserts every recipient's EARN balance rose by
/// exactly its AMOUNT before it writes the file.
///
/// @dev Why these 10 are owed: holders staked ESPN into sESPN-LP
/// (0xcD65F0b6E31e44225330DB8622a9e5307DDC6c1C), which deposits into the Arrakis V2 ESPN/USDS
/// vault (0x2F63AE2184D876f156b9eF21f488d4E6B442FaD7); the vault's liquidity sits in the Uniswap V3
/// ESPN/USDS 0.05% pool (0x6007905d106cA97f4Fe032d818e815657122b01E). That pool was not excluded
/// from the block 26043909 EARN snapshot, so the ESPN it held got no EARN and is stuck there
/// (unrecoverable) -- this batch mints the EARN each holder's ESPN would have earned instead.
///
/// Formula (same as 004-stry-migration/Distribute.s.sol:85), all at block 26043909:
///   sespnlpComponent = floor(sESPNLP_bal * sESPNLP_totalAssets / sESPNLP_totalSupply)
///   arrakisShares    = sespnlpComponent + directArrakisShares
///   espnEq           = floor(arrakisShares * arrakisUnderlyingESPN / arrakisTotalSupply)
///   AMOUNT           = floor(espnEq * ESPN_totalAssets / (ESPN_totalSupply * 100))
///
/// Snapshot constants (block 26043909; ESPN totalAssets/totalSupply also in
/// script/deployments/1/config/espn-holders-26043909.json):
///   sESPN-LP totalAssets = 63296406706707716788, totalSupply = 61850324259961958682
///   Arrakis totalSupply  = 63310748483716381372
///   Arrakis totalUnderlying(vault).amount0 (ESPN, via ArrakisV2Helper) = 64098954667490100895
///   ESPN totalAssets = 3878657270739417700998339, totalSupply = 34719892443431448328525
contract ProposeCompensation is Script {
    uint256 internal constant RECIPIENT_COUNT = 10;

    function run() external virtual {
        address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        address earn = ConfigLib.addr("deploymentAddresses.json", ".stry");
        require(
            !vm.exists(SafeBatchLib.path(safe, "007-earn-espn-staker-compensation", 1)),
            "ProposeCompensation: batch 001 already exists; delete it deliberately to regenerate"
        );
        require(earn.code.length > 0, "ProposeCompensation: .stry has no code");
        require(StryToken(earn).owner() == safe, "ProposeCompensation: EARN.owner() != redemption Safe");

        (address[] memory recipients, uint256[] memory amounts) = _recipients();
        SafeBatchLib.Tx[] memory txs = buildBatch(earn, recipients, amounts);
        _simulateAndCheck(earn, recipients, amounts, txs);

        SafeBatchLib.write(
            safe,
            "007-earn-espn-staker-compensation",
            1,
            "EARN ESPN staker compensation mint",
            "Mints the missed EARN for sESPN-LP stakers and direct Arrakis ESPN/USDS vault holders, whose ESPN sat in the Uniswap V3 pool at the block 26043909 snapshot.",
            txs
        );
        console2.log(
            "Simulation passed; batch written:", SafeBatchLib.path(safe, "007-earn-espn-staker-compensation", 1)
        );
    }

    function buildBatch(address earn, address[] memory recipients, uint256[] memory amounts)
        internal
        pure
        returns (SafeBatchLib.Tx[] memory txs)
    {
        txs = new SafeBatchLib.Tx[](1);
        txs[0] = SafeBatchLib.Tx({to: earn, data: abi.encodeCall(StryToken.mintBatch, (recipients, amounts))});
    }

    /// @dev The one check this batch needs: fork-simulate it as the Safe and assert every
    /// recipient's EARN balance rose by exactly its AMOUNT, no more, no less.
    function _simulateAndCheck(
        address earn,
        address[] memory recipients,
        uint256[] memory amounts,
        SafeBatchLib.Tx[] memory txs
    ) internal {
        address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        uint256[] memory balancesBefore = new uint256[](recipients.length);
        for (uint256 i = 0; i < recipients.length; i++) {
            balancesBefore[i] = StryToken(earn).balanceOf(recipients[i]);
        }

        SafeBatchLib.execute(safe, txs);

        for (uint256 i = 0; i < recipients.length; i++) {
            require(
                StryToken(earn).balanceOf(recipients[i]) == balancesBefore[i] + amounts[i],
                "ProposeCompensation sim: EARN balance delta != amount"
            );
        }
    }

    /// @dev public (not internal) only so the fork test can read the hardcoded arrays without
    /// duplicating them.
    function _recipients() public pure returns (address[] memory recipients, uint256[] memory amounts) {
        recipients = new address[](RECIPIENT_COUNT);
        amounts = new uint256[](RECIPIENT_COUNT);

        // sESPN-LP shares 47503905022346121142 -> ~49.22 ESPN equivalent.
        recipients[0] = 0xC052EbF272dC644933Ef2c905b2e7ac3f90fDA93;
        amounts[0] = 54984834348075282701;

        // sESPN-LP shares 6910000000000000000 -> ~7.16 ESPN equivalent.
        recipients[1] = 0x8482a0F31050416AD4344C98bcdb938e9cD3DEa2;
        amounts[1] = 7998188889239141615;

        // sESPN-LP shares 5400000000000000000 -> ~5.60 ESPN equivalent.
        recipients[2] = 0x0A7562526191F8c9b49291768b847501caf3D11d;
        amounts[2] = 6250393632690501407;

        // sESPN-LP shares 1426362005970285407 -> ~1.48 ESPN equivalent.
        recipients[3] = 0xee614d9cb3438B981c79E0FE34830cD761233a2e;
        amounts[3] = 1650985925931170899;

        // sESPN-LP shares 425891847079119019 -> ~0.44 ESPN equivalent.
        recipients[4] = 0xF8b1bD226fb79bc18798F2e1617b2aE7761b7951;
        amounts[4] = 492961423925578190;

        // sESPN-LP shares 183906025230362686 -> ~0.19 ESPN equivalent.
        recipients[5] = 0xEF5dc16B42d2197895aE4884b3Db5B0ADe495dC8;
        amounts[5] = 212867601687644006;

        // Direct Arrakis shares 6188588844316200 (no sESPN-LP) -> ~0.0063 ESPN equivalent.
        recipients[6] = 0xdEf27D920Be434Fa870978c342671a9b7a7Bd271;
        amounts[6] = 6999518470308900;

        // Direct Arrakis shares 5469564390160100 (no sESPN-LP) -> ~0.0055 ESPN equivalent.
        recipients[7] = 0x25942088F3af0DC7b2E2a5cCBE31E48b87D399B9;
        amounts[7] = 6186275730473031;

        // sESPN-LP shares 259349336070429 AND direct Arrakis shares 2683620487364589 -> ~0.0030
        // ESPN equivalent combined.
        recipients[8] = 0x8Ca8cF00721a2077Ee3660b002fCc754aE9B83C8;
        amounts[8] = 3335463865878842;

        // sESPN-LP shares 9999999999 AND direct Arrakis shares 3286823695 -> ~1.37e-8 ESPN
        // equivalent combined.
        recipients[9] = 0xd2EFB273d369841aaDc1aaD3925eBBafC047512C;
        amounts[9] = 15292319847;
    }
}
