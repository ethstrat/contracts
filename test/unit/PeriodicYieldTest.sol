// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {StryToken} from "../../src/StryToken.sol";
import {StakedStrat} from "../../src/StakedStrat.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";
import {SafeBatchLib} from "../../script/deployments/1/lib/SafeBatchLib.sol";
import {PeriodicYield} from "../../script/deployments/1/004-stry-migration/PeriodicYield.s.sol";

/// @dev periodicYield/periodicYieldAmount/_periodicYieldAmountPure are `internal` on the
/// PeriodicYield Script contract -- a plain forge-std Test can't call them across instances.
/// This harness inherits PeriodicYield and re-exports what the tests need as `external`
/// wrappers. No fork, no Script/Test diamond-inheritance risk.
contract PeriodicYieldHarness is PeriodicYield {
    function exposedAmountPure(uint256 totalSupply_, uint256 basisPriceUsd, uint256 annualDividendRatioX100)
        external
        pure
        returns (uint256)
    {
        return _periodicYieldAmountPure(totalSupply_, basisPriceUsd, annualDividendRatioX100);
    }

    function exposedAmount(StakedStrat stakedEarn) external view returns (uint256) {
        return periodicYieldAmount(stakedEarn);
    }

    function exposedYield(address safe, address usds, address stakedEarnAddr)
        external
        view
        returns (SafeBatchLib.Tx[] memory)
    {
        return periodicYield(safe, usds, stakedEarnAddr);
    }
}

contract PeriodicYieldTest is Test {
    // Mirrors settings.json's real .espnv3.basisPriceUsd / .annualDividendRatioX100 -- kept in
    // sync by test_periodicYieldAmount_matchesRealConfig, the one test allowed to depend on the
    // committed file.
    uint256 internal constant BASIS_PRICE_USD = 100;
    uint256 internal constant ANNUAL_DIVIDEND_RATIO_X100 = 1500;

    PeriodicYieldHarness internal harness;
    StakedStrat internal stakedStrat;
    StryToken internal earn;
    MintableBurnableToken internal usds;
    ITripwireController internal ctrl;

    address internal guardian = address(0x9);
    address internal safe = address(0xA11CE);
    address internal holder = address(0xB0B);

    function setUp() public {
        harness = new PeriodicYieldHarness();
        ctrl = ITripwireController(address(new TripwireController()));
        usds = new MintableBurnableToken("USDS stand-in", "USDS", address(this), ctrl, address(this));
        usds.manageMinter(address(this), true);
    }

    function _deployStakedStrat(uint256 totalSupply_) internal {
        earn = new StryToken(address(this));
        address[] memory to = new address[](1);
        to[0] = holder;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalSupply_;
        earn.mintBatch(to, amounts);

        stakedStrat = new StakedStrat(address(earn), address(usds), ctrl, guardian);
    }

    function _stakeAll() internal {
        uint256 balance = earn.balanceOf(holder);
        vm.startPrank(holder);
        earn.approve(address(stakedStrat), balance);
        stakedStrat.stake(balance);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Amount formula
    // ---------------------------------------------------------------------

    function test_periodicYieldAmount_exact_roundSupply() public {
        _deployStakedStrat(1_000_000e18);
        uint256 expected = 1_000_000e18 * BASIS_PRICE_USD * ANNUAL_DIVIDEND_RATIO_X100 * 28 / 100 / 100 / 365;
        assertEq(harness.exposedAmountPure(earn.totalSupply(), BASIS_PRICE_USD, ANNUAL_DIVIDEND_RATIO_X100), expected);
    }

    function test_periodicYieldAmount_exact_nonRoundSupply() public {
        // Not a multiple of 3,650,000 -- exercises real truncation in the chained divisions,
        // not just a magnitude that happens to divide evenly.
        uint256 totalSupply_ = 7_777_777e18 + 1;
        _deployStakedStrat(totalSupply_);
        uint256 expected = totalSupply_ * BASIS_PRICE_USD * ANNUAL_DIVIDEND_RATIO_X100 * 28 / 100 / 100 / 365;
        assertEq(harness.exposedAmountPure(earn.totalSupply(), BASIS_PRICE_USD, ANNUAL_DIVIDEND_RATIO_X100), expected);
    }

    function test_periodicYieldAmount_matchesRealConfig() public {
        _deployStakedStrat(1_000_000e18);
        assertEq(
            harness.exposedAmount(stakedStrat),
            harness.exposedAmountPure(earn.totalSupply(), BASIS_PRICE_USD, ANNUAL_DIVIDEND_RATIO_X100)
        );
    }

    function test_periodicYieldAmount_revertsBelowRatioFloor() public {
        vm.expectRevert(bytes("PeriodicYield: implausible annualDividendRatioX100"));
        harness.exposedAmountPure(1_000_000e18, BASIS_PRICE_USD, 0);
    }

    function test_periodicYieldAmount_revertsAboveRatioCeiling() public {
        vm.expectRevert(bytes("PeriodicYield: implausible annualDividendRatioX100"));
        harness.exposedAmountPure(1_000_000e18, BASIS_PRICE_USD, 3001);
    }

    function test_periodicYieldAmount_succeedsAtRatioCeiling() public view {
        // Boundary is inclusive -- 3000 itself must not revert.
        harness.exposedAmountPure(1_000_000e18, BASIS_PRICE_USD, 3000);
    }

    // ---------------------------------------------------------------------
    // Safe-batch construction
    // ---------------------------------------------------------------------

    function test_periodicYield_revertsWhenNoStakers() public {
        _deployStakedStrat(1_000_000e18);
        usds.mint(safe, 1_000_000_000e18);
        vm.expectRevert(
            bytes(
                "PeriodicYield: totalStaked() == 0 -- funding now permanently destroys the deposit, see src/StakedStrat.sol syncRewards()"
            )
        );
        harness.exposedYield(safe, address(usds), address(stakedStrat));
    }

    function test_periodicYield_revertsWhenSafeBalanceBelowAmount() public {
        _deployStakedStrat(1_000_000e18);
        _stakeAll();
        uint256 amount = harness.exposedAmount(stakedStrat);
        usds.mint(safe, amount - 1);
        vm.expectRevert(bytes("PeriodicYield: Safe USDS balance < computed amount"));
        harness.exposedYield(safe, address(usds), address(stakedStrat));
    }

    function test_periodicYield_returnsExactTwoTxBatch() public {
        _deployStakedStrat(1_000_000e18);
        _stakeAll();
        uint256 amount = harness.exposedAmount(stakedStrat);
        usds.mint(safe, amount); // exactly the guard boundary -- must succeed, not revert

        SafeBatchLib.Tx[] memory txs = harness.exposedYield(safe, address(usds), address(stakedStrat));

        assertEq(txs.length, 2, "expected exactly 2 transactions");
        assertEq(txs[0].to, address(usds));
        assertEq(txs[0].data, abi.encodeCall(IERC20.transfer, (address(stakedStrat), amount)));
        assertEq(txs[1].to, address(stakedStrat));
        assertEq(txs[1].data, abi.encodeCall(StakedStrat.syncRewards, ()));
    }
}
