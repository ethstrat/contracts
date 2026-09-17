// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {EspnRedemptionToken} from "../../src/EspnRedemptionToken.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

contract EspnRedemptionTokenTest is Test {
    EspnRedemptionToken internal token;

    address internal owner = address(0x123);
    address internal user = address(0x789);

    function setUp() external {
        vm.prank(owner);
        token = new EspnRedemptionToken(owner);
        vm.stopPrank();
    }

    function _singleton(address to_, uint256 amount_)
        internal
        pure
        returns (address[] memory to, uint256[] memory amounts)
    {
        to = new address[](1);
        amounts = new uint256[](1);
        to[0] = to_;
        amounts[0] = amount_;
    }

    // Covers list item 1: single entry credits the recipient and moves totalSupply.
    function testMintBatchSingleEntry() external {
        (address[] memory to, uint256[] memory amounts) = _singleton(user, 100);

        vm.prank(owner);
        token.mintBatch(to, amounts);

        assertEq(token.balanceOf(user), 100);
        assertEq(token.totalSupply(), 100);
    }

    // Covers list items 2 and 7: only the owner may mintBatch, before and after renouncing.
    function testMintBatchAccessControl() external {
        (address[] memory to, uint256[] memory amounts) = _singleton(user, 100);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        token.mintBatch(to, amounts);

        vm.prank(owner);
        token.renounceOwnership();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        token.mintBatch(to, amounts);
    }

    // Covers list items 3, 5 and 8: mismatched lengths, a zero-address recipient, and an empty-array no-op.
    function testMintBatchValidation() external {
        address[] memory mismatchedTo = new address[](2);
        uint256[] memory mismatchedAmounts = new uint256[](1);
        mismatchedTo[0] = user;
        mismatchedTo[1] = owner;
        mismatchedAmounts[0] = 100;

        vm.prank(owner);
        vm.expectRevert(EspnRedemptionToken.LengthMismatch.selector);
        token.mintBatch(mismatchedTo, mismatchedAmounts);

        (address[] memory zeroTo, uint256[] memory zeroAmounts) = _singleton(address(0), 100);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.mintBatch(zeroTo, zeroAmounts);

        address[] memory emptyTo = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);
        vm.prank(owner);
        token.mintBatch(emptyTo, emptyAmounts);
        assertEq(token.totalSupply(), 0);
    }

    // Covers list item 4: 170 entries produce exactly the expected per-address balances and totalSupply.
    function testMintBatch170Entries() external {
        uint256 n = 170;
        address[] memory to = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 expectedTotal;
        for (uint256 i; i < n; ++i) {
            to[i] = address(uint160(i + 1));
            amounts[i] = (i + 1) * 1e18;
            expectedTotal += amounts[i];
        }

        vm.prank(owner);
        token.mintBatch(to, amounts);

        for (uint256 i; i < n; ++i) {
            assertEq(token.balanceOf(to[i]), amounts[i]);
        }
        assertEq(token.totalSupply(), expectedTotal);
    }

    // Covers list item 6: standard ERC20 behaviour (transfer, approve/transferFrom, metadata, decimals == 18).
    function testStandardErc20Behaviour() external {
        (address[] memory to, uint256[] memory amounts) = _singleton(user, 1000);
        vm.prank(owner);
        token.mintBatch(to, amounts);

        vm.prank(user);
        token.transfer(owner, 100);
        assertEq(token.balanceOf(user), 900);
        assertEq(token.balanceOf(owner), 100);

        vm.prank(user);
        token.approve(owner, 200);
        vm.prank(owner);
        token.transferFrom(user, owner, 200);
        assertEq(token.balanceOf(user), 700);
        assertEq(token.balanceOf(owner), 300);

        assertEq(token.name(), "ESPN Redemption");
        assertEq(token.symbol(), "ESPNR");
        assertEq(token.decimals(), 18);
    }
}
