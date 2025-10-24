// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ESPNRedemptionFacilitator} from "../../src/ESPNRedemptionFacilitator.sol";
import {EthStrategyPerpetualNote} from "../../src/EthStrategyPerpetualNote.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

contract ESPNRedemptionFacilitatorProdSimTest is Test {
    ESPNRedemptionFacilitator public facilitator;
    EthStrategyPerpetualNote public espn;
    IERC20 public usds;
    
    address public manager = address(0x2);
    address public user = address(0x664Ca7eEe02aD47f438bD5c282D40d19A8838ADC);
    
    uint256 public constant DEPOSIT_AMOUNT = 100 * 10**18;
    uint256 public constant WITHDRAW_AMOUNT = 99 * 10**18;

    function setUp() public {
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL"), 23644992));

        usds = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);
        espn = EthStrategyPerpetualNote(0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE);
        
        // Deploy facilitator
        facilitator = new ESPNRedemptionFacilitator(address(espn), manager);

        // User deposits to ESPN
        vm.startPrank(user);
        usds.approve(address(espn), DEPOSIT_AMOUNT);
        espn.deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();

        // fund facilitator with USDS
        vm.prank(user);
        usds.transfer(address(facilitator), DEPOSIT_AMOUNT * 2);
    }

    function test_FacilitateRedeem_Success() public {
        // Approve facilitator to spend ESPN shares
        uint256 shares = espn.balanceOf(user);
        vm.prank(user);
        espn.approve(address(facilitator), shares);
        
        // Execute redeem
        uint256 receiverBalanceBefore = usds.balanceOf(user);
        vm.prank(user);
        uint256 assetsReceived = facilitator.redeem(shares);
        
        // Verify results
        assertEq(espn.balanceOf(user), 0);
        assertEq(usds.balanceOf(user), receiverBalanceBefore + assetsReceived);
        assertEq(usds.balanceOf(address(espn)), 1 wei);
    }

    function test_FacilitateRedeem_InsufficientBalance() public {
        // Try to redeem more shares than user has
        uint256 excessiveShares = espn.balanceOf(user) + 1;
        
        vm.prank(user);
        espn.approve(address(facilitator), excessiveShares);
        
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            ERC4626.ERC4626ExceededMaxRedeem.selector,
            user,
            excessiveShares,
            excessiveShares - 1
        ));
        facilitator.redeem(excessiveShares);
    }

    function test_FacilitateRedeem_InsufficientAllowance() public {
        // User doesn't approve facilitator for ESPN shares
        uint256 shares = espn.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector,
            address(facilitator),
            0,
            shares
        )); // ESPN will revert with ERC20InsufficientAllowance
        facilitator.redeem(shares);
    }

    function test_FacilitateWithdraw_Success() public {
        uint256 userSharesBefore = espn.balanceOf(user);
        uint256 userUsdsBalanceBefore = usds.balanceOf(user);
        
        // Approve facilitator to spend ESPN shares
        vm.prank(user);
        espn.approve(address(facilitator), userSharesBefore);
        
        // Execute withdraw
        vm.prank(user);
        uint256 sharesBurned = facilitator.withdraw(WITHDRAW_AMOUNT);
        
        // Verify results
        assertEq(espn.balanceOf(user), userSharesBefore - sharesBurned);
        assertEq(usds.balanceOf(user), userUsdsBalanceBefore + WITHDRAW_AMOUNT);
        assertApproxEqAbs(espn.convertToAssets(espn.balanceOf(user)), 1 ether, 1 gwei);
        assertEq(usds.balanceOf(address(espn)), 1 wei);
    }

    function test_FacilitateWithdraw_InsufficientAllowance() public {
        // User doesn't approve facilitator for ESPN shares
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector,
            address(facilitator),
            0,
            espn.previewWithdraw(WITHDRAW_AMOUNT)
        ));
        facilitator.withdraw(WITHDRAW_AMOUNT);
    }
}
