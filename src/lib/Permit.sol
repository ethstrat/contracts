// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

library Permit {
    struct IPermitApproval {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function getEmptyApproval() internal pure returns (IPermitApproval memory) {
        return IPermitApproval({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});
    }

    function validatePermit(
        ERC20Permit permit_,
        address owner_,
        address spender_,
        uint256 value_,
        IPermitApproval memory approval_
    ) internal {
        // If the deadline is 0, it is empty and no permit is required
        // The standard approval checks will revert if the owner has not provided an approval
        if (approval_.deadline == 0) return;

        // Validate
        permit_.permit(owner_, spender_, value_, approval_.deadline, approval_.v, approval_.r, approval_.s);
    }
}
