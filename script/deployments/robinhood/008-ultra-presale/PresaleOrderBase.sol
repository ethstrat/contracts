// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISeaportMinimal} from "../../1/003-espn-redemption/interfaces/ISeaportMinimal.sol";
import {BuildOrderLib} from "../../1/003-espn-redemption/BuildOrderLib.sol";
import {RobinhoodBatchWriter} from "../lib/RobinhoodBatchWriter.sol";

/// @dev Single source of truth for the 008-ultra-presale multisig output directory, shared with
/// GrantMinter.s.sol so the two can't drift apart. A free file-level constant (not a contract member)
/// so GrantMinter can import it without inheriting PresaleOrderBase's Seaport-specific surface.
string constant PRESALE_008_DIR = "script/deployments/robinhood/multisig/008-ultra-presale/";

/// @notice Shared order shape for closing the ULTRA presale. One PARTIAL_OPEN Seaport order from the Safe:
/// offer `offerAmount` of `offerToken`, consideration `receiptAmount` pULTRA paid to the Safe.
///   convert: offer ULTRA, offerAmount = ultraPerReceipt * receiptAmount
///   refund : offer WETH,  offerAmount = receiptAmount (1:1, the presale price)
/// offerAmount is always an integer multiple of receiptAmount, so a holder fills with
/// numerator = their pULTRA balance, denominator = receiptAmount, and both legs divide exactly
/// (no fill grid, no InexactFraction, no dust left in holder wallets).
abstract contract PresaleOrderBase is RobinhoodBatchWriter {
    /// @dev Seaport 1.6, same address on every chain. Code verified on Robinhood Chain 2026-09-29.
    ISeaportMinimal internal constant SEAPORT = ISeaportMinimal(0x0000000000000068F116a894984e2DB1123eB395);

    function _dir() internal pure override returns (string memory) {
        return PRESALE_008_DIR;
    }

    struct OrderSpec {
        address safe;
        address offerToken;
        uint256 offerAmount;
        address receipt;
        uint256 receiptAmount;
        uint256 startTime;
        uint256 endTime;
        string salt;
    }

    function _orderParams(OrderSpec memory s) internal pure returns (ISeaportMinimal.OrderParameters memory) {
        BuildOrderLib.TokenAndAmount[] memory offers = new BuildOrderLib.TokenAndAmount[](1);
        offers[0] = BuildOrderLib.TokenAndAmount({token: s.offerToken, amount: s.offerAmount});
        BuildOrderLib.TokenAndAmount[] memory asks = new BuildOrderLib.TokenAndAmount[](1);
        asks[0] = BuildOrderLib.TokenAndAmount({token: s.receipt, amount: s.receiptAmount});
        return BuildOrderLib.constructOrderParams(
            s.safe,
            BuildOrderLib.Order({
                offers: offers,
                asks: asks,
                askRecipient: s.safe,
                startTimestamp: s.startTime,
                endTimestamp: s.endTime,
                salt: bytes(s.salt)
            })
        );
    }

    function _orderHash(ISeaportMinimal.OrderParameters memory params) internal view returns (bytes32) {
        return SEAPORT.getOrderHash(BuildOrderLib.toOrderComponents(params, SEAPORT.getCounter(params.offerer)));
    }

    function _mode(string memory mode) internal pure returns (bool isConvert) {
        bytes32 m = keccak256(bytes(mode));
        require(m == keccak256("convert") || m == keccak256("refund"), "MODE must be convert or refund");
        return m == keccak256("convert");
    }
}
