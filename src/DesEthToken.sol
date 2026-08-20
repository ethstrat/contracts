// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "./MintableBurnableToken.sol";

/**
 * @title ETH Strategy deployed ETH receipt token
 */
contract DesEthToken is MintableBurnableToken {
    constructor(address owner, ITripwireController controller_, address guardian_)
        MintableBurnableToken("ETH Strategy Deployed ETH", "desETH", owner, controller_, guardian_)
    {}
}
