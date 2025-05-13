// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../../src/StratPresale.sol";
import "../../src/StratOption.sol";

contract StratPresaleTest is Test {
    StratPresale private presale;
    StratOption private stratOption;
    address presaleMultisig = address(0x123);
    address internal owner = address(0x123);
    address internal user1 = address(0x1111);
    address internal user2 = address(0x2222);

    function setUp() public {
        vm.startPrank(owner);
        stratOption = new StratOption(owner);
        presale = new StratPresale(address(stratOption), presaleMultisig);
        stratOption.manageMinter(address(presale), true);
        vm.stopPrank();
    }

    function testMintRevertsIfNoEthSent() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(StratPresale.NoEthSent.selector));
        presale.mint();
        vm.stopPrank();
    }

    function testMintSuccessfully() public {
        uint256 valueToSend = 2 ether;
        vm.deal(user1, valueToSend);
        vm.startPrank(user1);

        presale.mint{value: valueToSend}();

        assertEq(presaleMultisig.balance, valueToSend);
        assertEq(user1.balance, 0);

        checkPresaleNFTInvariants(1, 20_000 ether);
        assertEq(stratOption.balanceOf(user1), 1);
        assertEq(presaleMultisig.balance, 2 ether);
        vm.stopPrank();
    }

    function testMultiplePresalers() public {
        vm.deal(user1, 5 ether);
        vm.deal(user2, 5 ether);

        // First contribution from user1
        vm.prank(user1);
        presale.mint{value: 2 ether}();
        checkPresaleNFTInvariants(1, 20_000 ether);
        assertEq(stratOption.balanceOf(user1), 1);
        assertEq(presaleMultisig.balance, 2 ether);

        // First contribution from user2, after some time
        vm.warp(block.timestamp + 1 hours);
        vm.prank(user2);
        presale.mint{value: 3 ether}();
        checkPresaleNFTInvariants(2, 30_000 ether);
        assertEq(stratOption.balanceOf(user2), 1);
        assertEq(presaleMultisig.balance, 5 ether);

        // Second contribution from user1, again after some time
        vm.warp(block.timestamp + 1 hours);
        vm.prank(user1);
        presale.mint{value: 2 ether}();
        checkPresaleNFTInvariants(3, 20_000 ether);
        assertEq(stratOption.balanceOf(user1), 2);
        assertEq(presaleMultisig.balance, 7 ether);
    }

    function checkPresaleNFTInvariants(uint256 tokenId, uint256 expectedNotionalUnderlyingAmount) internal view {
        assertEq(stratOption.strikeAmount(tokenId), 0);
        assertEq(stratOption.notionalUnderlyingAmount(tokenId), expectedNotionalUnderlyingAmount);
        assertEq(stratOption.notionalUSDAmount(tokenId), 0);
        assertEq(stratOption.expiry(tokenId), block.timestamp + (420 * 365 days));
        assertEq(stratOption.timelock(tokenId), block.timestamp); // no timelock for presale

        assertGt(stratOption.expiry(tokenId), stratOption.timelock(tokenId));
        assertGt(stratOption.expiry(tokenId), block.timestamp);
        assertGe(stratOption.timelock(tokenId), block.timestamp); // no timelock for presale
    }
}
