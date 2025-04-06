// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Permit} from "../../src/lib/Permit.sol";

abstract contract PermitGenerator is Test {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _getPermitOwnerSignature(
        address owner_,
        uint256 ownerPk_,
        address spender_,
        uint256 deadline_,
        uint256 amount_,
        bytes32 domainSeparator_
    ) internal view returns (Permit.IPermitApproval memory) {
        bytes32 hashStruct = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender_, amount_, 0, deadline_));
        bytes32 permitHash = keccak256(abi.encodePacked(uint16(0x1901), domainSeparator_, hashStruct));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk_, permitHash);

        return Permit.IPermitApproval({deadline: deadline_, v: v, r: r, s: s});
    }
}
