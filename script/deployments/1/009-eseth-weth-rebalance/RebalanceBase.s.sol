// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {esETH} from "src/esETH.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";
import {SafeBatchDecodedLib} from "../lib/SafeBatchDecodedLib.sol";

interface ISafe {
    function nonce() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool);
}

interface IWETH9 {
    function withdraw(uint256 wad) external;
    function approve(address guy, uint256 wad) external returns (bool);
}

/// @notice Shared plumbing for the fortnightly esETH WETH rebalance scripts (RedepositEth,
/// ConvertToStEth): `AMOUNT` parsing (whole ETH), pre-checks, Safe nonce log, Safe simulation through
/// the real `execTransaction` + MultiSendCallOnly, and the raw + decoded batch writers. Never broadcasts.
abstract contract RebalanceBase is Script {
    function safe() internal view returns (address) {
        return ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.unencumbered");
    }

    function eseth() internal view returns (address) {
        return ConfigLib.addr("deploymentAddresses.json", ".esETH");
    }

    function weth() internal view returns (address) {
        return ConfigLib.addr("externalAddresses.json", ".WETH");
    }

    function multiSendCallOnly() internal view returns (address) {
        return ConfigLib.addr("externalAddresses.json", ".safe.multiSendCallOnly");
    }

    /// @dev AMOUNT is whole ETH; a wei value passed by mistake trips the WETH balance cap in `_checkCommon`.
    function _amountWei(uint256 amountEth) internal returns (uint256 amt) {
        require(amountEth > 0, "Rebalance: AMOUNT must be > 0");
        amt = amountEth * 1 ether;
        console2.log("AMOUNT (ETH)", amountEth);
        console2.log("amt (wei)", amt);
    }

    function _checkCommon(uint256 amt) internal view {
        esETH e = esETH(payable(eseth()));
        address s = safe();
        address w = weth();
        require(e.treasuryManager() == s, "Rebalance: esETH.treasuryManager() != Safe");
        require(e.isMinter(s), "Rebalance: Safe is not an esETH minter");
        (esETH.TokenType tokenType,,, uint256 totalMinted) = e.tokenConfigs(w);
        require(tokenType == esETH.TokenType.ERC20, "Rebalance: WETH tokenType != ERC20");
        require(amt <= IERC20(w).balanceOf(address(e)), "Rebalance: AMOUNT > WETH.balanceOf(esETH)");
        require(amt <= totalMinted, "Rebalance: AMOUNT > esETH WETH totalMinted");
        require(amt + 1 <= e.balanceOf(s), "Rebalance: AMOUNT + 1 > esETH.balanceOf(Safe)");
    }

    function _logNonce() internal view {
        console2.log("Safe nonce (on-chain, excludes Safe queue)", ISafe(safe()).nonce());
    }

    /// @dev Executes the batch as the Safe via the real execTransaction + MultiSendCallOnly. Not
    /// SafeBatchLib.execute: WETH.withdraw reverts under vm.prank(SAFE) (2300 stipend, cold proxy).
    function _simulate(SafeBatchDecodedLib.Tx[] memory txs) internal {
        address s = safe();
        uint256 wethBefore = IERC20(weth()).balanceOf(s);
        uint256 ethBefore = s.balance;

        bytes memory packed;
        for (uint256 i = 0; i < txs.length; i++) {
            // uint256 value, never a narrower type: a truncated value still executes
            packed = abi.encodePacked(packed, uint8(0), txs[i].to, txs[i].value, txs[i].data.length, txs[i].data);
        }
        ISafe sf = ISafe(s);
        address ms = multiSendCallOnly(); // resolve before vm.prank: only execTransaction may carry the prank
        if (sf.getThreshold() > 1) vm.store(s, bytes32(uint256(4)), bytes32(uint256(1))); // fork-only
        address owner = sf.getOwners()[0];
        bytes memory sig = abi.encodePacked(uint256(uint160(owner)), bytes32(0), uint8(1));
        bytes memory msData = abi.encodeWithSignature("multiSend(bytes)", packed);
        vm.prank(owner);
        bool ok = sf.execTransaction(ms, 0, msData, 1, 0, 0, 0, address(0), payable(address(0)), sig);
        require(ok, "Rebalance sim: execTransaction returned false");

        require(IERC20(weth()).balanceOf(s) == wethBefore, "Rebalance sim: WETH stranded in Safe");
        require(s.balance == ethBefore, "Rebalance sim: ETH stranded in Safe");
    }

    function _in(string memory name, string memory typ, string memory value)
        internal
        pure
        returns (SafeBatchDecodedLib.Input memory)
    {
        return SafeBatchDecodedLib.Input(name, typ, typ, value);
    }
}
