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
        presale = new StratPresale(stratOption, presaleMultisig);
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
        assertEq(address(this).balance, 0);

        assertEq(stratOption.balanceOf(address(this)), 1);
        assertEq(stratOption.strikeAmount(1), 1 ether);
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
        assertEq(stratOption.strikeAmount(1), 1 ether);
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
}
