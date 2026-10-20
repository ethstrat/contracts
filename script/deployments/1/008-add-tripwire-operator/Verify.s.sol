// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {esETH} from "src/esETH.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {ProposeAddTripwireOperator} from "./ProposeAddTripwireOperator.s.sol";

/// @notice Post-execution check (run against a fork where the batch executed, or mainnet after it
/// lands): every (target, operator) pair is an operator and WETH is redeemable on esETH with
/// tokenType ERC20 / isMintable true unchanged. Reverts on any mismatch.
contract Verify is ProposeAddTripwireOperator {
    function run() external view override {
        address[5] memory t = targets();
        address[2] memory ops = [OPERATOR_1, OPERATOR_2];
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = 0; j < 2; j++) {
                require(controller().isOperator(t[i], ops[j]), "Verify: operator missing");
            }
        }
        esETH eseth = esETH(payable(ConfigLib.addr("deploymentAddresses.json", ".esETH")));
        (esETH.TokenType tokenType, bool isMintable, bool isRedeemable,) = eseth.tokenConfigs(WETH);
        require(tokenType == esETH.TokenType.ERC20 && isMintable, "Verify: WETH type/isMintable changed");
        require(isRedeemable, "Verify: WETH not redeemable");
    }
}
