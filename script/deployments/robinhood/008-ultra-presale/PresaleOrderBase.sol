// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ISeaportMinimal} from "../../1/003-espn-redemption/interfaces/ISeaportMinimal.sol";
import {BuildOrderLib} from "../../1/003-espn-redemption/BuildOrderLib.sol";
import {SafeBatchLib} from "../../1/lib/SafeBatchLib.sol";

/// @notice Shared order shape for closing the ULTRA presale. One PARTIAL_OPEN Seaport order from the Safe:
/// offer `offerAmount` of `offerToken`, consideration `receiptAmount` pULTRA paid to the Safe.
///   convert: offer ULTRA, offerAmount = ultraPerReceipt * receiptAmount
///   refund : offer WETH,  offerAmount = receiptAmount (1:1, the presale price)
/// offerAmount is always an integer multiple of receiptAmount, so a holder fills with
/// numerator = their pULTRA balance, denominator = receiptAmount, and both legs divide exactly
/// (no fill grid, no InexactFraction, no dust left in holder wallets).
abstract contract PresaleOrderBase is Script {
    /// @dev Seaport 1.6, same address on every chain. Code verified on Robinhood Chain 2026-09-29.
    ISeaportMinimal internal constant SEAPORT = ISeaportMinimal(0x0000000000000068F116a894984e2DB1123eB395);
    string internal constant DIR = "script/deployments/robinhood/multisig/008-ultra-presale/";

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

    function _writeBatch(
        string memory file,
        address safe,
        string memory name,
        string memory description,
        SafeBatchLib.Tx[] memory txs
    ) internal {
        require(!vm.exists(file), string.concat(file, " already exists; delete it deliberately to regenerate"));
        vm.createDir(DIR, true);
        vm.writeFile(file, _json(safe, name, description, txs));
        console2.log("Simulation passed; batch written:", file);
    }

    /// @dev Same Safe Transaction Builder schema as SafeBatchLib.write, which hardcodes chain 1.
    function _json(address safe, string memory name, string memory description, SafeBatchLib.Tx[] memory txs)
        internal
        view
        returns (string memory)
    {
        string memory transactions;
        for (uint256 i = 0; i < txs.length; i++) {
            string memory entry = string.concat(
                "{\"to\":\"",
                vm.toString(txs[i].to),
                "\",\"value\":\"0\",\"data\":\"",
                vm.toString(txs[i].data),
                "\",\"contractMethod\":null,\"contractInputsValues\":null}"
            );
            transactions = i == 0 ? entry : string.concat(transactions, ",", entry);
        }
        return string.concat(
            "{\"version\":\"1.0\",\"chainId\":\"",
            vm.toString(block.chainid),
            "\",\"createdAt\":",
            vm.toString(block.timestamp * 1000),
            ",\"meta\":{\"name\":\"",
            name,
            "\",\"description\":\"",
            description,
            "\",\"txBuilderVersion\":\"2.0.1\",\"createdFromSafeAddress\":\"",
            vm.toString(safe),
            "\",\"createdFromOwnerAddress\":\"\",\"checksum\":null},\"transactions\":[",
            transactions,
            "]}"
        );
    }

    function _file(string memory prefix, address safe) internal pure returns (string memory) {
        bytes memory full = bytes(vm.toString(safe));
        bytes memory short = new bytes(10);
        for (uint256 i = 0; i < 10; i++) {
            short[i] = full[i];
        }
        return string.concat(DIR, prefix, "-", string(short), "-multisig.json");
    }
}
