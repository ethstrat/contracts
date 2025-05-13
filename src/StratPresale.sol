// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IStratOption} from "./interfaces/IStratOption.sol";

/**
 * @title StratPresale Contract
 * @notice Manages presale minting operations by forwarding funds to the multisig wallet and interfacing with
 *         the option minter contract. Presale NFTs are 1 to 1 with ETH (with a unit bias captured at redemption),
 *         we leverage the the same option as the rest of the system for simplicity
 */
contract StratPresale {
    /// @dev the option minter
    IStratOption public stratOption;

    /// @dev The gnosis multisig dev that receives the funds collected during the presale.
    address public immutable presaleMultisig;

    // Errors
    error NoEthSent();
    error EthTransferFailed();

    /// @notice Event triggered on each presale mint
    event PresaleMint(address indexed from, uint256 value);

    uint256 public constant UNIT_BIAS = 10_000;

    constructor(address _stratOption, address _presaleMultisig) {
        stratOption = IStratOption(_stratOption);
        presaleMultisig = _presaleMultisig;
    }

    /**
     * @notice Mints NFT capturing presale settlement using the sent ETH and forwards the ETH to the presale multisig.
     * @dev STRAT is minted at redemption 1:1 (with a unit bias captured at redemption) to the ETH sent. NFT can be
     * redeemed
     *      for STRAT 120 days from the moment of mint
     */
    function mint() external payable {
        if (msg.value == 0) revert NoEthSent();

        stratOption.mint(
            msg.sender, // owner
            0, // Strike amount
            msg.value * UNIT_BIAS, // Underlying amount
            0, // Underlying USD amount, cannot be redeemed
            block.timestamp + (420 * 365 days), // Expiry
            block.timestamp // no timelock for presale. Vest is handled seperately
        );

        // send ETH to presale multisig
        (bool success,) = presaleMultisig.call{value: msg.value}("");
        if (!success) revert EthTransferFailed();

        emit PresaleMint(msg.sender, msg.value);
    }
}
