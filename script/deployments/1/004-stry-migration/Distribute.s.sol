// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StryToken} from "src/StryToken.sol";
import {EthStrategyPerpetualNote} from "src/EthStrategyPerpetualNote.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {HoldersLib} from "../lib/HoldersLib.sol";

/// @notice Deploys STRY and mints it to the same snapshot holders as Track A, in one mintBatch,
/// sized so totalSupply(STRY) * basisPriceUsd == the included holders' share of ESPN's live USDS
/// backing. $100/STRY is a nominal basis price, not a redemption guarantee (Assumption 7/option 2)
/// -- both tracks lay claim to the same ESPN backing.
contract Distribute is Script {
    function run() external virtual {
        address deployer = msg.sender;
        vm.startBroadcast();
        StryToken stry = distribute(deployer);
        vm.stopBroadcast();

        ConfigLib.writeDeployedAddress(".stry", address(stry));
    }

    /// @dev Items 1-3 and the calibration assertion. `writeDeployedAddress` stays out of here and
    /// only runs from run(), so Verify.s.sol never dirties the committed deploymentAddresses.json.
    /// `deployer` is taken as an argument (not read via msg.sender) so Verify.s.sol can prank as
    /// whichever address it likes and pass the same address through as the constructor owner.
    function distribute(address deployer) internal returns (StryToken stry) {
        string memory holdersFile = vm.envString("HOLDERS_FILE");
        HoldersLib.Snapshot memory snapshot = HoldersLib.load(holdersFile);
        (address[] memory addrs, uint256[] memory espnBalances, uint256 includedCount,) = HoldersLib.included(snapshot);

        address espnAddr = ConfigLib.addr("externalAddresses.json", ".eth-strategy.espn");
        EthStrategyPerpetualNote espn = EthStrategyPerpetualNote(espnAddr);
        uint256 totalAssets_ = espn.totalAssets();
        uint256 totalSupply_ = espn.totalSupply();
        uint256 basisPriceUsd = ConfigLib.num("settings.json", ".espnv3.basisPriceUsd");

        uint256[] memory stryAmounts = new uint256[](includedCount);
        for (uint256 i; i < includedCount; ++i) {
            stryAmounts[i] = espnBalances[i] * totalAssets_ / (totalSupply_ * basisPriceUsd);
        }

        stry = new StryToken(deployer);

        uint256 gasBefore = gasleft();
        stry.mintBatch(addrs, stryAmounts);
        uint256 executionGas = gasBefore - gasleft();
        uint256 calldataGasEstimate = 21000 + includedCount * 20 * 16;
        console2.log("mintBatch execution gas:", executionGas);
        console2.log(
            "mintBatch total estimated (execution + 21000 intrinsic + calldata):", executionGas + calldataGasEstimate
        );

        stry.renounceOwnership();

        // Calibration -- each per-holder division truncates up to 1 wei of STRY; multiplied back
        // by basisPriceUsd, that is up to basisPriceUsd wei of USDS per holder. Truncation only
        // undershoots, never overshoots.
        uint256 espnBackingRepresented = HoldersLib.sum(espnBalances) * totalAssets_ / totalSupply_;
        require(
            stry.totalSupply() * basisPriceUsd <= espnBackingRepresented, "Distribute: STRY oversized vs ESPN backing"
        );
        require(
            espnBackingRepresented - stry.totalSupply() * basisPriceUsd <= includedCount * basisPriceUsd,
            "Distribute: STRY undersized beyond truncation tolerance"
        );

        console2.log("STRY distributed to included holders:", includedCount);
        console2.log("NOTE: basisPriceUsd is a nominal basis price, not a redemption guarantee.");
    }
}
