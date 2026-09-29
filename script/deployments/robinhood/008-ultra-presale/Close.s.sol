// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MintableBurnableToken} from "src/MintableBurnableToken.sol";
import {UltraPresale} from "src/UltraPresale.sol";
import {ISeaportMinimal} from "../../1/003-espn-redemption/interfaces/ISeaportMinimal.sol";
import {SafeBatchLib} from "../../1/lib/SafeBatchLib.sol";
import {PresaleOrderBase} from "./PresaleOrderBase.sol";

/// @notice Builds the Safe batch that closes the ULTRA presale with one Seaport order. Never broadcasts; the
/// offerer is the Safe. Simulates the batch as the Safe on the fork before writing it.
///
///   MODE=convert: revoke collector minter, mint ULTRA_PER_RECEIPT * outstanding pULTRA to the Safe (temporary
///                 self-grant, revoked in the same batch), approve Seaport, validate order ULTRA -> pULTRA.
///   MODE=refund : revoke collector minter, approve Seaport, validate order WETH -> pULTRA at 1:1. The Safe must
///                 already hold that much WETH (wrap forwarded ETH first).
///
/// ULTRA_PER_RECEIPT is whole ULTRA per 1 ETH contributed (both 18 decimals), chosen from the option actually
/// bought: floor(ULTRA backed by the purchase / ETH raised). Integer by design so every fill divides exactly;
/// the rounding (< 1 ULTRA per ETH) stays with the treasury.
///
/// Env: OWNER (the Safe), ROBINHOOD_CHAIN_ID, PRESALE (UltraPresale), MODE, ORDER_START, ORDER_END, ORDER_SALT;
/// convert only: ULTRA_TOKEN, ULTRA_PER_RECEIPT.
///
/// forge script script/deployments/robinhood/008-ultra-presale/Close.s.sol:Close --fork-url $ROBINHOOD_RPC
///
/// Output: script/deployments/robinhood/multisig/008-ultra-presale/001-<mode>-<safe>-multisig.json. Record the
/// logged order hash and amounts; Finish.s.sol needs them.
contract Close is PresaleOrderBase {
    struct Params {
        address safe;
        UltraPresale presale;
        bool isConvert;
        address ultra;
        uint256 ultraPerReceipt;
        uint256 startTime;
        uint256 endTime;
        string salt;
    }

    function run() external {
        require(block.chainid == vm.envUint("ROBINHOOD_CHAIN_ID"), "wrong chain: block.chainid != ROBINHOOD_CHAIN_ID");
        string memory mode = vm.envString("MODE");
        bool isConvert = _mode(mode);
        Params memory p = Params({
            safe: vm.envAddress("OWNER"),
            presale: UltraPresale(vm.envAddress("PRESALE")),
            isConvert: isConvert,
            ultra: isConvert ? vm.envAddress("ULTRA_TOKEN") : address(0),
            ultraPerReceipt: isConvert ? vm.envUint("ULTRA_PER_RECEIPT") : 0,
            startTime: vm.envUint("ORDER_START"),
            endTime: vm.envUint("ORDER_END"),
            salt: vm.envString("ORDER_SALT")
        });

        (SafeBatchLib.Tx[] memory txs, OrderSpec memory spec) = build(p);
        bytes32 orderHash = simulate(spec, txs);

        _writeBatch(
            _file(string.concat("001-", mode), p.safe),
            p.safe,
            isConvert ? "ULTRA presale: convert pULTRA to ULTRA" : "ULTRA presale: refund pULTRA for WETH",
            "Revokes the presale collector's minter role, sets up the offer asset, approves Seaport and validates the partial-fill order. Execute in the order listed.",
            txs
        );
        _logRunBook(spec, orderHash);
    }

    /// @dev All preflight requires live here. Public so tests can build the batch without env.
    function build(Params memory p) public view returns (SafeBatchLib.Tx[] memory txs, OrderSpec memory spec) {
        require(p.safe.code.length > 0, "Close: OWNER has no code");
        require(address(SEAPORT).code.length > 0, "Close: Seaport not deployed on this chain");
        require(p.presale.safe() == p.safe, "Close: presale funds went to a different Safe");
        require(block.timestamp >= p.presale.end(), "Close: presale still open");
        require(p.startTime < p.endTime && p.endTime > block.timestamp, "Close: bad order window");

        MintableBurnableToken receipt = MintableBurnableToken(address(p.presale.receipt()));
        uint256 outstanding = receipt.totalSupply() - receipt.balanceOf(p.safe);
        require(outstanding > 0, "Close: no pULTRA outstanding");

        spec = OrderSpec({
            safe: p.safe,
            offerToken: p.isConvert ? p.ultra : address(p.presale.weth()),
            offerAmount: 0,
            receipt: address(receipt),
            receiptAmount: outstanding,
            startTime: p.startTime,
            endTime: p.endTime,
            salt: p.salt
        });

        bool revokeCollector = receipt.minters(address(p.presale));
        uint256 n = (revokeCollector ? 1 : 0) + (p.isConvert ? 5 : 2);
        txs = new SafeBatchLib.Tx[](n);
        uint256 i;
        if (revokeCollector) {
            txs[i++] = SafeBatchLib.Tx({
                to: address(receipt),
                data: abi.encodeCall(MintableBurnableToken.manageMinter, (address(p.presale), false))
            });
        }

        if (p.isConvert) {
            require(p.ultraPerReceipt > 0, "Close: ULTRA_PER_RECEIPT is zero");
            require(MintableBurnableToken(p.ultra).owner() == p.safe, "Close: Safe does not own ULTRA");
            spec.offerAmount = p.ultraPerReceipt * outstanding;
            txs[i++] =
                SafeBatchLib.Tx({to: p.ultra, data: abi.encodeCall(MintableBurnableToken.manageMinter, (p.safe, true))});
            txs[i++] = SafeBatchLib.Tx({
                to: p.ultra,
                data: abi.encodeCall(MintableBurnableToken.mint, (p.safe, spec.offerAmount))
            });
            txs[i++] = SafeBatchLib.Tx({
                to: p.ultra,
                data: abi.encodeCall(MintableBurnableToken.manageMinter, (p.safe, false))
            });
        } else {
            spec.offerAmount = outstanding;
            require(
                IERC20(spec.offerToken).balanceOf(p.safe) >= outstanding,
                "Close: Safe WETH < outstanding pULTRA; wrap first"
            );
        }

        txs[i++] = SafeBatchLib.Tx({
            to: spec.offerToken,
            data: abi.encodeCall(IERC20.approve, (address(SEAPORT), spec.offerAmount))
        });
        ISeaportMinimal.Order[] memory orders = new ISeaportMinimal.Order[](1);
        orders[0] = ISeaportMinimal.Order({parameters: _orderParams(spec), signature: ""});
        txs[i++] = SafeBatchLib.Tx({to: address(SEAPORT), data: abi.encodeCall(ISeaportMinimal.validate, (orders))});
    }

    /// @dev Executes `txs` as the Safe on the current fork and requires the end state.
    function simulate(OrderSpec memory spec, SafeBatchLib.Tx[] memory txs) public returns (bytes32 orderHash) {
        orderHash = _orderHash(_orderParams(spec));
        SafeBatchLib.execute(spec.safe, txs);

        (bool isValidated, bool isCancelled, uint256 totalFilled,) = SEAPORT.getOrderStatus(orderHash);
        require(isValidated && !isCancelled && totalFilled == 0, "Close sim: order not validated and unfilled");
        require(
            IERC20(spec.offerToken).allowance(spec.safe, address(SEAPORT)) >= spec.offerAmount,
            "Close sim: Seaport allowance too low"
        );
        require(
            IERC20(spec.offerToken).balanceOf(spec.safe) >= spec.offerAmount, "Close sim: Safe cannot cover the offer"
        );
    }

    function _logRunBook(OrderSpec memory spec, bytes32 orderHash) private pure {
        console2.log("order hash (EXPECTED_ORDER_HASH for Finish):");
        console2.logBytes32(orderHash);
        console2.log("OFFER_AMOUNT   =", spec.offerAmount);
        console2.log("RECEIPT_AMOUNT =", spec.receiptAmount);
        console2.log("--- holder fill ---");
        console2.log("approve Seaport for your pULTRA balance, then fulfillAdvancedOrder with");
        console2.log("  numerator   = your pULTRA balance");
        console2.log("  denominator = RECEIPT_AMOUNT");
        console2.log("  you receive = your pULTRA balance * OFFER_AMOUNT / RECEIPT_AMOUNT");
    }
}
