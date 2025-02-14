// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {StratOption} from "./StratOption.sol";

contract StratOptionExercise {
    IERC20MintableBurnable public immutable cdtToken;
    IERC20MintableBurnable public immutable stratToken;
    StratOption public immutable stratOption;

    error NotOwnerOrApproved(address account, uint256 tokenId);
    error TimelockActive(address account, uint256 tokenId);
    error OptionExpired(address account, uint256 tokenId);

    event OptionExercised(address indexed optionOwner, uint256 tokenId, uint256 strike, uint256 strat);

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
        if (stratOption.timelock(tokenId) > block.timestamp) revert TimelockActive(msg.sender, tokenId);
        if (stratOption.expiry(tokenId) < block.timestamp) revert OptionExpired(msg.sender, tokenId);

        address optionOwner = stratOption.ownerOf(tokenId);

        uint256 strike = stratOption.strikeAmount(tokenId);
        uint256 strat = stratOption.notionalUnderlyingAmount(tokenId);

        cdtToken.burnFrom(msg.sender, strike);
        stratToken.mint(optionOwner, strat);
        stratOption.burn(tokenId);

        emit OptionExercised(optionOwner, tokenId, strike, strat);
    }
}
