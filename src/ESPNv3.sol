// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "./MintableBurnableToken.sol";

/**
 * @title ETH Strategy Perpetual Note v3
 */
contract ESPNv3 is MintableBurnableToken {
    constructor(address owner, ITripwireController controller_, address guardian_)
        MintableBurnableToken("ETH Strategy Perpetual Note v3", "ESPNv3", owner, controller_, guardian_)
    {}
}
