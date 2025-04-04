// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import "../../../src/StratPresale.sol";
import "../../../src/StratOption.sol";

contract StratPresaleTest is Test {
    event PresaleMint(address indexed from, uint256 value, uint256 tokenId);

    StratPresale private presale;
    StratOption private stratOption;
    address presaleMultisig = address(0x123);
    address internal owner = address(0x123);
    address internal user = address(0x456);

    uint48 internal constant BASE_TIMESTAMP = 1000000;

    function setUp() public {
        vm.startPrank(owner);
        stratOption = new StratOption(owner);
        presale = new StratPresale(1000 ether, address(stratOption), presaleMultisig, BASE_TIMESTAMP);
        stratOption.manageMinter(address(presale), true);
        vm.stopPrank();
    }

    // when no ETH is sent
    //  [X] it reverts
    // when the cap is exceeded
    //  [X] it reverts
    // [X] it updates the total raised
    // [X] it updates the contributions for the caller
    // [X] it mints the STRAT option to the caller
    // [X] it does not mint CDT tokens to the caller
    // [X] it sends the ETH to the presale multisig
    // [X] it emits a PresaleMint event

    function testMintRevertsIfNoEthSent() public {
        vm.expectRevert(bytes("No ETH sent"));
        presale.mint();
    }

    function testMintSuccessfully() public {
        uint256 valueToSend = 2 ether;
        vm.deal(user, valueToSend);

        // Expected quantity of options
        uint256 expectedTokenId =
            stratOption.getTokenId(1e18, 0, BASE_TIMESTAMP + (420 * 365 days), BASE_TIMESTAMP + (90 days), true);

        vm.expectEmit();
        emit PresaleMint(user, valueToSend, expectedTokenId);

        vm.prank(user);
        uint256 tokenId = presale.mint{value: valueToSend}();

        assertEq(presaleMultisig.balance, valueToSend);
        assertEq(presale.totalRaised(), valueToSend);
        assertEq(user.balance, 0);

        assertEq(tokenId, expectedTokenId, "Incorrect token ID");

        assertEq(stratOption.balanceOf(user, tokenId), valueToSend, "balance");

        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId);

        assertEq(option.strikePrice, 1e18, "strikePrice");
        assertEq(option.redemptionPrice, 0, "redemptionPrice");

        // STRAT output
        assertEq(valueToSend * 1e18 / option.strikePrice, valueToSend, "STRAT output");

        assertEq(option.expiry, uint48(BASE_TIMESTAMP + (420 * 365 days)), "expiry");
        assertEq(option.timelock, uint48(BASE_TIMESTAMP + (90 days)), "timelock");
        assertEq(option.requiresInputBurn, true, "requiresInputBurn");
    }

    function testMintCapEnforced() public {
        // Mint 1
        uint256 valueToSend = 999 ether;
        vm.deal(user, valueToSend);
        vm.prank(user);
        presale.mint{value: valueToSend}();

        // Mint 2
        valueToSend = 1 ether;
        vm.deal(user, valueToSend);
        vm.prank(user);
        presale.mint{value: valueToSend}();

        // Mint 3
        valueToSend = 1 ether;
        vm.deal(user, valueToSend);
        vm.expectRevert(bytes("Cap reached"));
        vm.prank(user);
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
