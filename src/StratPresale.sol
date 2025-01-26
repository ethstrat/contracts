// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import "./StratOption.sol";

contract StratPresale {
    StratOption public stratOption;
    address public immutable presaleMultisig;
    uint256 public immutable cap;
    uint256 public totalRaised = 0;

    // @dev Contribution per address. Technically not needed, but saves
    // having to setup chain indexers for presale dapp
    mapping(address => uint256) public contributions;

    constructor(uint256 _cap, StratOption _stratOption, address _presaleMultisig) {
        cap = _cap;
        stratOption = _stratOption;
        presaleMultisig = _presaleMultisig;
    }

    function mint() external payable {
        require(msg.value > 0, "No ETH sent");

        totalRaised += msg.value;
        require(totalRaised <= cap, "Cap reached");

        contributions[msg.sender] += msg.value;

        stratOption.mint(
            msg.sender, msg.value, msg.value, 0, block.timestamp + (420 * 365 days), block.timestamp + 90 days
        );

        // send ETH to presale multisig
        (bool success,) = presaleMultisig.call{value: msg.value}("");
        require(success, "Transfer failed");
    }
}
