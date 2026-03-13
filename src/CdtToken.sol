// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "./MintableBurnableToken.sol";

/**
 * @title STRAT perpetual debt receipt token
 */
contract CdtToken is MintableBurnableToken {
    constructor(address owner, ITripwireController controller_, address guardian_) MintableBurnableToken("ETH Strategy Debt", "CDT", owner, controller_, guardian_) {}
}
