// SPDX-License-Identifier: GPL-V2
pragma solidity ^0.8.20;

import "./MintableBurnableToken.sol";

/**
 * @title The STRAT Token
 */
contract StratToken is MintableBurnableToken {
    constructor(address owner, ITripwireController controller_, address guardian_) MintableBurnableToken("ETH Strategy", "STRAT", owner, controller_, guardian_) {}
}
