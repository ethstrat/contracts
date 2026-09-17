// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {EspnRedemptionToken} from "src/EspnRedemptionToken.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {HoldersLib} from "../lib/HoldersLib.sol";

/// @notice Deploys `EspnRedemptionToken`, airdrops it 1:1 with snapshot ESPN balances in a single
/// `mintBatch`, then renounces ownership. See Task 4 Step 19.
contract Distribute is Script {
    function run() external virtual {
        string memory holdersFile = vm.envString("HOLDERS_FILE");

        vm.startBroadcast();
        address deployer = msg.sender;
        EspnRedemptionToken token = _distribute(deployer, holdersFile);
        vm.stopBroadcast();

        // Kept out of `_distribute` and out of the broadcast so `Verify.s.sol` — which calls
        // `_distribute` directly under a prank, never `run()` — can never dirty the committed
        // deploymentAddresses.json (Step 19).
        ConfigLib.writeDeployedAddress(".espn-redemption-token", address(token));
    }

    /// @dev Shared with `Verify.s.sol`, which calls this under `vm.startPrank(deployer)` instead
    /// of broadcasting. Performs the real mint + renounce and asserts the airdrop is exact.
    function _distribute(address deployer, string memory holdersFile) internal returns (EspnRedemptionToken token) {
        HoldersLib.Snapshot memory snapshot = HoldersLib.load(holdersFile);
        (address[] memory addrs, uint256[] memory balances, uint256 includedCount, uint256 excludedCount) =
            HoldersLib.included(snapshot);

        token = new EspnRedemptionToken(deployer);

        bytes memory mintCalldata = abi.encodeCall(token.mintBatch, (addrs, balances));
        uint256 gasBefore = gasleft();
        token.mintBatch(addrs, balances);
        uint256 gasAfter = gasleft();

        token.renounceOwnership();

        require(token.totalSupply() == HoldersLib.sum(balances), "Distribute: totalSupply mismatch");
        require(token.owner() == address(0), "Distribute: ownership not renounced");
        for (uint256 i = 0; i < addrs.length; i++) {
            require(token.balanceOf(addrs[i]) == balances[i], "Distribute: balance mismatch");
        }

        console2.log("holders included:", includedCount);
        console2.log("holders excluded:", excludedCount);
        console2.log("total minted:", token.totalSupply());
        _logGas("mintBatch", gasBefore - gasAfter, mintCalldata);
    }

    /// @dev Step 23 gas-logging format. `gasBefore - gasAfter` inside a single script frame is
    /// execution gas only — it excludes the transaction's 21,000 intrinsic cost and its calldata
    /// cost, so both are logged separately rather than glossed over.
    function _logGas(string memory label, uint256 executionGas, bytes memory txCalldata) internal pure {
        uint256 calldataGas;
        for (uint256 i = 0; i < txCalldata.length; i++) {
            calldataGas += txCalldata[i] == 0 ? 4 : 16;
        }
        console2.log(string.concat(label, " execution gas:"), executionGas);
        console2.log(
            string.concat(label, " total estimated (execution + 21000 intrinsic + calldata):"),
            executionGas + 21_000 + calldataGas
        );
    }
}
