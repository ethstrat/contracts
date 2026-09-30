// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "./MintableBurnableToken.sol";

/**
 * @title ULTRA token
 */
contract UltraToken is MintableBurnableToken {
    constructor(address owner, ITripwireController controller_, address guardian_)
        MintableBurnableToken("UltraETH", "ULTRA", owner, controller_, guardian_)
    {}
}
