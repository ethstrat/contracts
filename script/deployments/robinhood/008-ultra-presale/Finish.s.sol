// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MintableBurnableToken} from "src/MintableBurnableToken.sol";
import {ISeaportMinimal} from "../../1/003-espn-redemption/interfaces/ISeaportMinimal.sol";
import {BuildOrderLib} from "../../1/003-espn-redemption/BuildOrderLib.sol";
import {SafeBatchLib} from "../../1/lib/SafeBatchLib.sol";
import {PresaleOrderBase} from "./PresaleOrderBase.sol";

/// @notice Builds the Safe batch that ends a Close.s.sol order: cancel it (whatever is unfilled), revoke the
/// Seaport allowance, and burn the pULTRA the Safe has collected from fills. Never broadcasts. Rebuilds the order
/// from the exact amounts Close logged and requires the hash to match, so it cancels the order that was validated.
/// Unfilled ULTRA (convert) or WETH (refund) stays on the Safe.
///
/// Env: OWNER, ROBINHOOD_CHAIN_ID, MODE, OFFER_TOKEN (ULTRA or WETH), OFFER_AMOUNT, RECEIPT_TOKEN, RECEIPT_AMOUNT,
/// ORDER_START, ORDER_END, ORDER_SALT, EXPECTED_ORDER_HASH.
///
/// forge script script/deployments/robinhood/008-ultra-presale/Finish.s.sol:Finish --fork-url $ROBINHOOD_RPC
contract Finish is PresaleOrderBase {
    function run() external {
        require(block.chainid == vm.envUint("ROBINHOOD_CHAIN_ID"), "wrong chain: block.chainid != ROBINHOOD_CHAIN_ID");
        string memory mode = vm.envString("MODE");
        _mode(mode);
        OrderSpec memory spec = OrderSpec({
            safe: vm.envAddress("OWNER"),
            offerToken: vm.envAddress("OFFER_TOKEN"),
            offerAmount: vm.envUint("OFFER_AMOUNT"),
            receipt: vm.envAddress("RECEIPT_TOKEN"),
            receiptAmount: vm.envUint("RECEIPT_AMOUNT"),
            startTime: vm.envUint("ORDER_START"),
            endTime: vm.envUint("ORDER_END"),
            salt: vm.envString("ORDER_SALT")
        });

        SafeBatchLib.Tx[] memory txs = build(spec, vm.envBytes32("EXPECTED_ORDER_HASH"));
        simulate(spec, txs);

        _writeBatch(
            _file(string.concat("002-finish-", mode), spec.safe),
            spec.safe,
            "ULTRA presale: finish order",
            "Cancels the presale close order, revokes the Seaport allowance and burns the pULTRA collected from fills. Execute in the order listed.",
            txs
        );
    }

    function build(OrderSpec memory spec, bytes32 expectedOrderHash)
        public
        view
        returns (SafeBatchLib.Tx[] memory txs)
    {
        ISeaportMinimal.OrderParameters memory params = _orderParams(spec);
        ISeaportMinimal.OrderComponents[] memory components = new ISeaportMinimal.OrderComponents[](1);
        components[0] = BuildOrderLib.toOrderComponents(params, SEAPORT.getCounter(spec.safe));
        require(
            SEAPORT.getOrderHash(components[0]) == expectedOrderHash,
            "Finish: rebuilt order hash does not match EXPECTED_ORDER_HASH"
        );

        uint256 collected = IERC20(spec.receipt).balanceOf(spec.safe);
        txs = new SafeBatchLib.Tx[](collected > 0 ? 3 : 2);
        txs[0] = SafeBatchLib.Tx({to: address(SEAPORT), data: abi.encodeCall(ISeaportMinimal.cancel, (components))});
        txs[1] = SafeBatchLib.Tx({to: spec.offerToken, data: abi.encodeCall(IERC20.approve, (address(SEAPORT), 0))});
        if (collected > 0) {
            txs[2] = SafeBatchLib.Tx({to: spec.receipt, data: abi.encodeCall(MintableBurnableToken.burn, (collected))});
        }
        console2.log("pULTRA collected from fills, burned:", collected);
    }

    function simulate(OrderSpec memory spec, SafeBatchLib.Tx[] memory txs) public {
        bytes32 orderHash = _orderHash(_orderParams(spec));
        SafeBatchLib.execute(spec.safe, txs);
        (, bool isCancelled,,) = SEAPORT.getOrderStatus(orderHash);
        require(isCancelled, "Finish sim: order not cancelled");
        require(
            IERC20(spec.offerToken).allowance(spec.safe, address(SEAPORT)) == 0, "Finish sim: allowance not revoked"
        );
        require(IERC20(spec.receipt).balanceOf(spec.safe) == 0, "Finish sim: pULTRA left on Safe");
    }
}
