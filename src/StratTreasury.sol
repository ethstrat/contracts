// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/**
 * @title Query and pull ETH from the treasury
 * @notice This contracts acts as a staging area for ETH that can be claimed from treasury. We
 *         limit our risk exposure by only keeping a small amount of ETH in this contract based on
 *         the amount of ETH we expect to be redeemable
 */
contract StratTreasury is Ownable2Step {
    mapping(address => bool) public canWithdraw;
    uint256 public totalDeployedEth;
    address public treasuryVault;

    error WithdrawUnauthorizedAccount(address account);
    error WithdrawFailed(address account);

    constructor(address vault, address owner) Ownable(owner) {
        treasuryVault = vault;
    }

    /**
     * @dev Allows only the owner to manage who can withdraw eth.
     */
    function manageWithdrawer(address who, bool enabled) external onlyOwner {
        canWithdraw[who] = enabled;
    }

    /**
     * @dev Allows only the owner to update the treasury vault.
     */
    function setTreasuryVault(address vault) external onlyOwner {
        treasuryVault = vault;
    }

    /**
     * @dev Allows only the owner to set the total amount of deployed ETH
     */
    function setDeployedEth(uint256 amount) external onlyOwner {
        totalDeployedEth = amount;
    }

    function withdraw(uint256 amount, address to) external {
        if (canWithdraw[msg.sender] == false) revert WithdrawUnauthorizedAccount(msg.sender);

        (bool success,) = to.call{value: amount}("");
        if (!success) revert WithdrawFailed(msg.sender);
    }

    function total() external view returns (uint256) {
        return treasuryVault.balance + totalDeployedEth + address(this).balance;
    }

    receive() external payable {
        // solhint-disable-previous-line no-empty-blocks
    }
}
