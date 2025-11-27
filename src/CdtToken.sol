// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "./MintableBurnableToken.sol";

/**
 * @title STRAT perpetual debt receipt token
 */
contract CdtToken is MintableBurnableToken {
    constructor(address owner) MintableBurnableToken("ETH Strategy Debt", "CDT", owner) {}
}
