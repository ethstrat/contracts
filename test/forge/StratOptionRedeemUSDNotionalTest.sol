// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PermitGenerator} from "../lib/Permit.sol";
import {EthUsdPriceOracleProvider} from "../lib/EthUsdPriceOracleProvider.sol";

import "../../src/StratOptionRedeemUSDNotional.sol";
import "../../src/StratOption.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";
import "../../src/interfaces/ITreasury.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

import {MockTreasury} from "../mocks/MockTreasury.sol";

contract StratOptionRedeemUSDNotionalTest is Test, PermitGenerator, EthUsdPriceOracleProvider {
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;
    StratOptionRedeemUSDNotional public optionRedeem;

    MockTreasury public mockTreasury;

    address internal owner = address(0x123);
    address internal user = address(0x789);
    address internal permitOwner;
    uint256 internal permitPk;

    /// @dev ETH price: $2000
    uint256 internal _ETH_USD_INITIAL_PRICE = 2000e18;

    function setUp() public {
        (permitOwner, permitPk) = makeAddrAndKey("PERMIT_OWNER");

        vm.startPrank(owner);
        // Deploy tokens and mocks
        cdtToken = new CdtToken(owner);
        stratToken = new StratToken(owner);
        stratOption = new StratOption(owner);
        mockTreasury = new MockTreasury();
        mockTreasury.setWithdrawAllowed(true); // Allow withdrawals for testing
        _setUpEthUsdOracle(_ETH_USD_INITIAL_PRICE);

        // Deploy target contract
        optionRedeem = new StratOptionRedeemUSDNotional(
            address(cdtToken), address(mockTreasury), address(ethUsdOracle), address(stratOption)
        );

        // Enable minting
        cdtToken.manageMinter(owner, true);
        stratToken.manageMinter(owner, true);
        stratOption.manageMinter(owner, true);

        // Give the treasury some initial balance
        vm.deal(address(mockTreasury), 100 ether);

        // Mint user some CDT, and mint an option with a notionalUSD of 500
        cdtToken.mint(user, 1000 ether);
        stratOption.mint(user, 0, 0, 500 ether, block.timestamp + 3600, block.timestamp + 1800);

        vm.stopPrank();
    }

    function _mintOption(address to_) internal {
        vm.prank(owner);
        stratOption.mint(to_, 0, 0, 500 ether, block.timestamp + 3600, block.timestamp + 1800);
    }

    function testRedeemSuccessTreasuryGtDebt() public {
        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        vm.startPrank(user);

        cdtToken.approve(address(optionRedeem), 500 ether);
        stratOption.approve(address(optionRedeem), 1);

        optionRedeem.redeemCdtForUsdNotional(1);

        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 500 ether, "CDT should be partially burned");
        // In this case: if treasury.total() * price >= totalDebt, so withdraw should be $500 of ETH at 2k / ETH
        assertEq(address(user).balance, 0.25 ether, "should withdraw $500 of ETH (0.25 ETH)");

        vm.stopPrank();
    }

    function testRedeemSuccessTreasuryLtDebt() public {
        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);
        // Set price to 7.5.  This will pass if CDT is burnt after, fail if CDT is calculated before
        ethUsdOracle.setBasePerQuote(7.5e18);

        vm.startPrank(user);

        cdtToken.approve(address(optionRedeem), 500 ether);
        stratOption.approve(address(optionRedeem), 1);

        optionRedeem.redeemCdtForUsdNotional(1);

        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 500 ether, "CDT should be partially burned");
        // In this case: if treasury.total() * price < totalDebt, so withdraw should be half of treasury
        // (500 CDT out of a total of 1k CDT)
        assertEq(address(user).balance, 50 ether, "should withdraw half of all ETH in treasury");

        vm.stopPrank();
    }

    function testRevertIfTimelockActive() public {
        // Before timelock
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.TimelockActive.selector, user, 1));
        optionRedeem.redeemCdtForUsdNotional(1);
        vm.stopPrank();
    }

    function testRevertIfOptionUnexpired() public {
        // before expiry, after timelock
        vm.warp(block.timestamp + 1801);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.OptionUnexpired.selector, user, 1));
        optionRedeem.redeemCdtForUsdNotional(1);
        vm.stopPrank();
    }

    function testRevertIfNotOptionOwner() public {
        // Advance time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);
        address randoUser = address(0x999);

        vm.prank(owner);
        cdtToken.mint(randoUser, 1000 ether);

        // Prank some random user
        vm.startPrank(randoUser);
        cdtToken.approve(address(optionRedeem), 500 ether);

        vm.expectRevert();
        optionRedeem.redeemCdtForUsdNotional(1);

        vm.stopPrank();
    }

    // redeemCdtForUsdNotionalWithPermit
    // given the deadline is 0
    //  given the caller has not approved spending of CDT
    //   [X] it reverts
    //  [X] it uses the existing spending allowance
    // given the deadline has passed
    //  [X] it reverts
    // given the signature is for another user
    //  [X] it reverts
    // given the caller is not the recipient
    //  given the signature is for the recipient
    //   [X] it reverts
    //  [X] it does not require approval to spend the CDT
    //  [X] it burns the CDT
    // given the signature is for a different spender
    //  [X] it reverts
    // given the signature is invalid
    //  [X] it reverts
    // [X] it does not require approval to spend the CDT
    // [X] it burns the CDT

    function test_redeemCdtForUsdNotionalWithPermit_deadlineIsZero_reverts() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Do NOT approve CDT spending

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionRedeem), 2);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval =
            Permit.IPermitApproval({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(optionRedeem), 0, 500 ether
            )
        );

        // Redeem
        vm.prank(permitOwner);
        optionRedeem.redeemCdtForUsdNotionalWithPermit(2, permitApproval);
    }

    function test_redeemCdtForUsdNotionalWithPermit_deadlineIsZero_spendingApprovalProvided() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Approve CDT spending
        vm.prank(permitOwner);
        cdtToken.approve(address(optionRedeem), 500 ether);

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionRedeem), 2);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval =
            Permit.IPermitApproval({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

        // Redeem
        vm.prank(permitOwner);
        optionRedeem.redeemCdtForUsdNotionalWithPermit(2, permitApproval);

        // Check balances
        assertEq(stratOption.balanceOf(permitOwner), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(permitOwner), 500 ether, "CDT should be partially burned");
        assertEq(address(permitOwner).balance, 0.25 ether, "should withdraw $500 of ETH (0.25 ETH)");
    }

    function test_redeemCdtForUsdNotionalWithPermit_deadlineHasPassed_reverts() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Do NOT approve CDT spending

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionRedeem), 2);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner, permitPk, address(optionRedeem), block.timestamp - 1, 500 ether, cdtToken.DOMAIN_SEPARATOR()
        );

        // Expect revert
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, block.timestamp - 1));

        // Redeem
        vm.prank(permitOwner);
        optionRedeem.redeemCdtForUsdNotionalWithPermit(2, permitApproval);
    }

    function test_redeemCdtForUsdNotionalWithPermit_differentOwner_reverts() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Do NOT approve CDT spending

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionRedeem), 2);

        // Generate permit approval
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("NEW_OWNER");
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            newOwner,
            newOwnerPk,
            address(optionRedeem),
            block.timestamp + 1 days,
            500 ether,
            cdtToken.DOMAIN_SEPARATOR()
        );

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector, 0x3983b8126a249758567f81864598Cd15D8097638, permitOwner
            )
        );

        // Redeem
        vm.prank(permitOwner);
        optionRedeem.redeemCdtForUsdNotionalWithPermit(2, permitApproval);
    }

    function test_redeemCdtForUsdNotionalWithPermit_differentSpender_reverts() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Do NOT approve CDT spending

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionRedeem), 2);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner,
            permitPk,
            address(stratOption),
            block.timestamp + 1 days,
            500 ether,
            cdtToken.DOMAIN_SEPARATOR()
        );

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector, 0xe5A54C0A2Dba58236A62112044f84Bccdc90a62a, permitOwner
            )
        );

        // Redeem
        vm.prank(permitOwner);
        optionRedeem.redeemCdtForUsdNotionalWithPermit(2, permitApproval);
    }

    function test_redeemCdtForUsdNotionalWithPermit_invalidSignature_reverts() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Do NOT approve CDT spending

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionRedeem), 2);

        // Generate invalid signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(permitPk, keccak256("INVALID"));

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval =
            Permit.IPermitApproval({deadline: block.timestamp + 1 days, v: v, r: r, s: s});

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector, 0x1Aec31dFB7D8b1D36BcA6ac8964d87C281378Fa6, permitOwner
            )
        );

        // Redeem
        vm.prank(permitOwner);
        optionRedeem.redeemCdtForUsdNotionalWithPermit(2, permitApproval);
    }

    function test_redeemCdtForUsdNotionalWithPermit_callerNotRecipient() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        // Create a new user
        (address newUser, uint256 newUserPk) = makeAddrAndKey("NEW_USER");

        // Give new user CDT
        vm.prank(owner);
        cdtToken.mint(newUser, 1000 ether);

        // Do NOT approve CDT spending

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionRedeem), 2);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            newUser, newUserPk, address(optionRedeem), block.timestamp + 1 days, 500 ether, cdtToken.DOMAIN_SEPARATOR()
        );

        // Redeem as newUser should fail, as they aren't an operator
        vm.prank(newUser);
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.NotOwnerOrApproved.selector, newUser, 2));
        optionRedeem.redeemCdtForUsdNotionalWithPermit(2, permitApproval);

        // Exercise as new user only if the option owner has granted
        // newUser as an operator
        vm.prank(permitOwner);
        stratOption.setApprovalForAll(newUser, true);
        vm.prank(newUser);
        optionRedeem.redeemCdtForUsdNotionalWithPermit(2, permitApproval);

        // Check balances
        assertEq(stratOption.balanceOf(permitOwner), 0, "permitOwner: Option balance");
        assertEq(stratOption.balanceOf(newUser), 0, "newUser: Option balance");

        assertEq(stratToken.balanceOf(permitOwner), 0, "permitOwner: STRAT balance");
        assertEq(stratToken.balanceOf(newUser), 0, "newUser: STRAT balance");

        assertEq(cdtToken.balanceOf(permitOwner), 0, "permitOwner: CDT balance");
        assertEq(cdtToken.balanceOf(newUser), 500 ether, "newUser: CDT balance");

        assertEq(address(permitOwner).balance, 0.25 ether, "permitOwner: ETH balance");
    }

    function test_redeemCdtForUsdNotionalWithPermit_callerNotRecipient_permitFromRecipient_reverts() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        // Create a new user
        (address newUser,) = makeAddrAndKey("NEW_USER");

        // Give new user CDT
        vm.prank(owner);
        cdtToken.mint(newUser, 1000 ether);

        vm.prank(permitOwner);
        stratOption.setApprovalForAll(newUser, true);

        // Generate permit approval as the permit owner
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner,
            permitPk,
            address(optionRedeem),
            block.timestamp + 1 days,
            500 ether,
            cdtToken.DOMAIN_SEPARATOR()
        );

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector, 0xE5b91e3BC1F267A104ab4AEacF9328ae77c57EFb, newUser
            )
        );

        // Redeem
        vm.prank(newUser);
        optionRedeem.redeemCdtForUsdNotionalWithPermit(2, permitApproval);
    }

    function test_redeemCdtForUsdNotionalWithPermit() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Do NOT approve CDT spending

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionRedeem), 2);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner,
            permitPk,
            address(optionRedeem),
            block.timestamp + 1 days,
            500 ether,
            cdtToken.DOMAIN_SEPARATOR()
        );

        // Redeem
        vm.prank(permitOwner);
        optionRedeem.redeemCdtForUsdNotionalWithPermit(2, permitApproval);

        // Check balances
        assertEq(stratOption.balanceOf(permitOwner), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(permitOwner), 500 ether, "CDT should be partially burned");
        assertEq(address(permitOwner).balance, 0.25 ether, "should withdraw $500 of ETH (0.25 ETH)");
    }
}
