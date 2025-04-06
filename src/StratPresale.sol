// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";

/**
 * @title StratPresale Contract
 * @notice Manages presale minting operations by forwarding funds to the multisig wallet and interfacing with
 *         the option minter contract. Presale NFTs are 1 to 1 with ETH (with a unit bias captured at redemption),
 *         we leverage the the same option as the rest of the system for simplicity
 */
contract StratPresale {
    /// @dev the option minter
    IStratOptionMinter public stratOption;

    /// @dev The gnosis multisig dev that receives the funds collected during the presale.
    address public immutable presaleMultisig;

    // Errors
    error NoEthSent();
    error EthTransferFailed();

    /// @notice Event triggered on each presale mint
    event PresaleMint(address indexed from, uint256 value);

    uint256 public constant UNIT_BIAS = 10_000;

    constructor(address _stratOption, address _presaleMultisig) {
        stratOption = IStratOptionMinter(_stratOption);
        presaleMultisig = _presaleMultisig;
    }

    /**
     * @notice Mints NFT capturing presale settlement using the sent ETH and forwards the ETH to the presale multisig.
     * @dev STRAT is minted at redemption 1:1 (with a unit bias captured at redemption) to the ETH sent. NFT can be
     * redeemed
     *      for STRAT 120 days from the moment of mint
     *
     *      This function performs the following actions:
     *      - Validates the inputs
     *      - Updates the total amount of ETH raised
     *      - Updates the contribution made by the caller
     *      - Mints the STRAT option to the caller
     *      - Sends the ETH raised to the presale multisig
     *      - Emits a PresaleMint event
     *
     *      The function reverts if:
     *      - The value of the function call is 0
     *      - The updated total amount of ETH raised exceeds the cap
     *      - The ETH transfer to the presale multisig fails
     */
    function mint() external payable {
        if (msg.value == 0) revert NoEthSent();

        // Mint the STRAT option
        // When exercised, this will result in:
        // - `msg.value` STRAT tokens being minted to the caller
        //
        // e.g. if 2 ETH (2e18) is provided:
        // - Strike amount: 0
        // - Underlying amount: 2e18
        // - Can be exercised for 0 CDT (total input of 2 ETH + 2e18 CDT) for 2e18 STRAT
        stratOption.mint(
            msg.sender, // Owner
            0, // Strike amount
            msg.value * UNIT_BIAS, // Underlying amount
            0, // Underlying USD amount, cannot be redeemed
            block.timestamp + (420 * 365 days), // Expiry
            block.timestamp + 120 days // Timelock
        );

        // Send ETH to presale multisig
        (bool success,) = presaleMultisig.call{value: msg.value}("");
        if (!success) revert EthTransferFailed();

        emit PresaleMint(msg.sender, msg.value);
    }
}
