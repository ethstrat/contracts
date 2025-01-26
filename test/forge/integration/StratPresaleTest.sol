// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../../../src/StratPresale.sol";
import "../../../src/StratOption.sol";

contract StratPresaleTest is Test {
    StratPresale private presale;
    StratOption private stratOption;
    address presaleMultisig = address(0x123);

    function setUp() public {
        stratOption = new StratOption();
        presale = new StratPresale(1000 ether, stratOption, presaleMultisig);
        stratOption.manageMinter(address(presale), true);
    }

    function testMintRevertsIfNoEthSent() public {
        vm.expectRevert(bytes("No ETH sent"));
        presale.mint();
    }

    function testMintSuccessfully() public {
        uint256 valueToSend = 2 ether;
        vm.deal(address(this), valueToSend);
        presale.mint{value: valueToSend}();

        assertEq(presaleMultisig.balance, valueToSend);
        assertEq(presale.totalRaised(), valueToSend);
        assertEq(address(this).balance, 0);

        assertEq(stratOption.balanceOf(address(this)), 1);
        assertEq(stratOption.strikeAmount(1), 2 ether);
        assertEq(stratOption.notionalUnderlyingAmount(1), 2 ether);
        assertEq(stratOption.notionalUSDAmount(1), 0);
        assertEq(stratOption.expiry(1), block.timestamp + (420 * 365 days));
        assertEq(stratOption.timelock(1), block.timestamp + (90 days));

        assertGt(stratOption.expiry(1), stratOption.timelock(1));
        assertGt(stratOption.expiry(1), block.timestamp);
        assertGt(stratOption.timelock(1), block.timestamp);
    }

    function testMintCapEnforced() public {
        uint256 valueToSend = 999 ether;
        vm.deal(address(this), valueToSend);
        presale.mint{value: valueToSend}();

        assertEq(presaleMultisig.balance, valueToSend);
        assertEq(address(this).balance, 0);

        assertEq(stratOption.balanceOf(address(this)), 1);
        assertEq(stratOption.strikeAmount(1), 999 ether);
        assertEq(stratOption.notionalUnderlyingAmount(1), valueToSend);
        assertEq(stratOption.notionalUSDAmount(1), 0);
        assertEq(stratOption.expiry(1), block.timestamp + (420 * 365 days));
        assertEq(stratOption.timelock(1), block.timestamp + (90 days));

        assertGt(stratOption.expiry(1), stratOption.timelock(1));
        assertGt(stratOption.expiry(1), block.timestamp);
        assertGt(stratOption.timelock(1), block.timestamp);

        valueToSend = 1 ether;
        vm.deal(address(this), valueToSend);
        presale.mint{value: valueToSend}();

        assertEq(presaleMultisig.balance, 1000 ether);
        assertEq(presale.totalRaised(), 1000 ether);
        assertEq(address(this).balance, 0);

        assertEq(stratOption.balanceOf(address(this)), 2);
        assertEq(stratOption.strikeAmount(2), 1 ether);
        assertEq(stratOption.notionalUnderlyingAmount(2), valueToSend);
        assertEq(stratOption.notionalUSDAmount(2), 0);
        assertEq(stratOption.expiry(2), block.timestamp + (420 * 365 days));
        assertEq(stratOption.timelock(2), block.timestamp + (90 days));

        assertGt(stratOption.expiry(2), stratOption.timelock(2));
        assertGt(stratOption.expiry(2), block.timestamp);
        assertGt(stratOption.timelock(2), block.timestamp);

        valueToSend = 1 ether;
        vm.deal(address(this), valueToSend);
        vm.expectRevert(bytes("Cap reached"));
        presale.mint{value: valueToSend}();
    }

    function testContributionsPerAddress() public {
        address user1 = address(0x1111);
        address user2 = address(0x2222);

        vm.deal(user1, 5 ether);
        vm.deal(user2, 5 ether);

        // First contribution from user1
        vm.startPrank(user1);
        presale.mint{value: 2 ether}();
        vm.stopPrank();

        assertEq(presale.contributions(user1), 2 ether);
        assertEq(presale.totalRaised(), 2 ether);

        // First contribution from user2
        vm.startPrank(user2);
        presale.mint{value: 3 ether}();
        vm.stopPrank();

        assertEq(presale.contributions(user2), 3 ether);
        assertEq(presale.totalRaised(), 5 ether);

        // Second contribution from user1
        vm.startPrank(user1);
        presale.mint{value: 2 ether}();
        vm.stopPrank();

        assertEq(presale.contributions(user1), 4 ether);
        assertEq(presale.totalRaised(), 7 ether);
    }
}
