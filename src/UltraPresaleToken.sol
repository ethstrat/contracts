// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "./MintableBurnableToken.sol";

/**
 * @title ULTRA presale receipt token
 * @notice Minted 1:1 with wei contributed to `UltraPresale`. Converted to ULTRA after close by a Safe-signed
 *         Seaport order at the ratio set by the option purchase.
 */
contract UltraPresaleToken is MintableBurnableToken {
    constructor(address owner, ITripwireController controller_, address guardian_)
        MintableBurnableToken("UltraETH Presale", "pULTRA", owner, controller_, guardian_)
    {}
}
