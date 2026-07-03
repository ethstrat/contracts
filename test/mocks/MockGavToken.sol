// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";

contract MockGavToken is MintableBurnableToken {
    constructor(address owner) MintableBurnableToken("Mock GAV Token", "GAV", owner) {}
}

