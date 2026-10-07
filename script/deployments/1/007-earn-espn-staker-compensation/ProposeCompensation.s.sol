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

    function _recipients() internal pure returns (address[] memory recipients, uint256[] memory amounts) {
        recipients = new address[](RECIPIENT_COUNT);
        amounts = new uint256[](RECIPIENT_COUNT);

        recipients[0] = 0xC052EbF272dC644933Ef2c905b2e7ac3f90fDA93;
        amounts[0] = 54984834348075282701;

        recipients[1] = 0x8482a0F31050416AD4344C98bcdb938e9cD3DEa2;
        amounts[1] = 7998188889239141615;

        recipients[2] = 0x0A7562526191F8c9b49291768b847501caf3D11d;
        amounts[2] = 6250393632690501407;

        recipients[3] = 0xee614d9cb3438B981c79E0FE34830cD761233a2e;
        amounts[3] = 1650985925931170899;

        recipients[4] = 0xF8b1bD226fb79bc18798F2e1617b2aE7761b7951;
        amounts[4] = 492961423925578190;

        recipients[5] = 0xEF5dc16B42d2197895aE4884b3Db5B0ADe495dC8;
        amounts[5] = 212867601687644006;

        recipients[6] = 0xdEf27D920Be434Fa870978c342671a9b7a7Bd271;
        amounts[6] = 6999518470308900;

        recipients[7] = 0x25942088F3af0DC7b2E2a5cCBE31E48b87D399B9;
        amounts[7] = 6186275730473031;

        recipients[8] = 0x8Ca8cF00721a2077Ee3660b002fCc754aE9B83C8;
        amounts[8] = 3335463865878842;

        recipients[9] = 0xd2EFB273d369841aaDc1aaD3925eBBafC047512C;
        amounts[9] = 15292319847;
    }
}
