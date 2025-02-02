// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {StratOption} from "./StratOption.sol";

contract StratOptionExercise {
    IERC20MintableBurnable public immutable cdtToken;
    IERC20MintableBurnable public immutable stratToken;
    StratOption public immutable stratOption;

    error NotOwnerOrApproved(address account, uint256 tokenId);

    // TODO(nap): Events

    /**
     * @param _cdtToken The CDT token
     * @param _stratToken The STRAT token
     * @param _stratOption The STRAT option
     */
    constructor(address _cdtToken, address _stratToken, address _stratOption) {
        cdtToken = IERC20MintableBurnable(_cdtToken);
        stratToken = IERC20MintableBurnable(_stratToken);
        stratOption = StratOption(_stratOption);
    }

    function exercise(uint256 tokenId) external {
        require(stratOption.timelock(tokenId) < block.timestamp, "Exercise timelocked");
        require(stratOption.expiry(tokenId) > block.timestamp, "Option expired");

        address optionOwner = stratOption.ownerOf(tokenId);

        if (optionOwner != msg.sender && stratOption.getApproved(tokenId) != msg.sender) {
            revert NotOwnerOrApproved(msg.sender, tokenId);
        }

        cdtToken.burnFrom(msg.sender, stratOption.strikeAmount(tokenId));
        stratToken.mint(optionOwner, stratOption.notionalUnderlyingAmount(tokenId));
    }
}
