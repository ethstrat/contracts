// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMerklDistributionCreator} from "./interfaces/IMerklDistributionCreator.sol";
import {WeeklyYield} from "./WeeklyYield.s.sol";

/// @notice Verify.s.sol-only test fixture: a separate deployed instance (not address(this)) so a
/// call into weeklyYield() crosses a real CALL boundary vm.expectRevert can observe. Verify is a
/// Script, and forge script blocks a self-call via `this.foo()` ("Usage of `address(this)`
/// detected in script contract") -- the same `this.` wrapper trick ScriptLibsTest._loadExternal
/// uses works there only because that contract is a Test, not a Script. Lives in its own file, not
/// as a second contract in Verify.s.sol, because forge script refuses to run a target file that
/// declares more than one contract without an explicit --tc, and yarn verify:migration passes
/// none.
contract WeeklyYieldProbe is WeeklyYield {
    function weeklyYieldExternal(
        address safe,
        address usds,
        address stry,
        uint256 amount,
        uint32 startTimestamp,
        address[] memory blacklist
    ) external view returns (IMerklDistributionCreator.CampaignParameters memory, bytes32, string memory) {
        return weeklyYield(safe, usds, stry, amount, startTimestamp, blacklist);
    }
}
