// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import "./StratOption.sol";

contract StratPresale {
    StratOption public stratOption;
    address public immutable presaleMultisig;
    uint256 public cap = 1000 * 1e18;

    constructor(StratOption _stratOption, address _presaleMultisig) {
        stratOption = _stratOption;
        presaleMultisig = _presaleMultisig;
    }

    function mint() external payable {
        require(msg.value > 0, "No ETH sent");
        require(cap >= msg.value, "Cap reached");

        cap -= msg.value;

        stratOption.mint(
            msg.sender, msg.value, msg.value, 0, block.timestamp + (420 * 365 days), block.timestamp + 90 days
        );

        // send ETH to presale multisig
        (bool success,) = presaleMultisig.call{value: msg.value}("");
        require(success, "Transfer failed");
    }
}
