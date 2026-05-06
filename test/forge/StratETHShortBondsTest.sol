// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PermitGenerator} from "../lib/Permit.sol";
import {EthUsdPriceOracleProvider} from "../lib/EthUsdPriceOracleProvider.sol";
import {StratEthPriceOracleProvider} from "../lib/StratEthPriceOracleProvider.sol";

import "../../src/StratETHShortBonds.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";
import "../../src/StratOption.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract StratETHShortBondsTest is Test, PermitGenerator, EthUsdPriceOracleProvider, StratEthPriceOracleProvider {
    StratETHShortBonds public bonds;
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;

    address internal owner = address(0x123);
    address internal user = address(0x789);
    address internal bondConverter = address(0x989);

    address internal permitOwner;
    uint256 internal permitPk;

    /// @dev ETH price: $3000
    uint256 internal _ETH_USD_INITIAL_PRICE = 3000e18;

    /// @dev STRAT price: 1 ETH = $3000
    uint256 internal _STRAT_ETH_INITIAL_PRICE = 1e18;

    function setUp() public {
        // Block timestamp needs to be non-zero
        vm.warp(1_000_000);

        (permitOwner, permitPk) = makeAddrAndKey("PERMIT_OWNER");

        // Deploy the real contracts
        vm.startPrank(owner);
        cdtToken = new CdtToken(owner);
        stratToken = new StratToken(owner);
        stratOption = new StratOption(owner);

        // Deploy mock oracles
        _setUpEthUsdOracle(_ETH_USD_INITIAL_PRICE);
        _setUpStratEthOracle(_STRAT_ETH_INITIAL_PRICE, address(stratToken));

        // Deploy the StratETHShortBonds contract
        bonds = new StratETHShortBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            address(ethUsdOracle),
            address(stratEthOracle),
            bondConverter,
            1e18, // BCV
            owner
        );

        stratToken.manageMinter(owner, true);
        stratToken.manageMinter(address(bonds), true);
        cdtToken.manageMinter(owner, true);

        // Mint tokens to initialize the supply (So it's non-zero)
        stratToken.mint(address(this), 1000e18);
        cdtToken.mint(address(this), 2000000e18);

        // Give bonding contract ability to mint StratOption
        stratOption.manageMinter(address(bonds), true);
        vm.stopPrank();
    }

    function testOnlyOwnerCanSetBCV() public {
        // A non-owner attempting to change BCV should fail
        vm.prank(user);
        vm.expectRevert();
        bonds.setBCV(5); // Should revert because user is not the owner

        // A owner attempting to change BCV should suceed
        vm.prank(owner);
        bonds.setBCV(5);
        assertEq(bonds.bcv(), 5, "BCV should be updated to 5000");
    }

    function testBondRevertIfNoCDTSent() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(StratETHShortBonds.ZeroAmount.selector));
        bonds.bond(user, 0, 0, block.timestamp + 1 hours); // Should revert because no CDT is sent
    }

    function testBondDeadlineInPastReverts() public {
        uint256 cdtAmount = 1000 ether;

        cdtToken.approve(address(bonds), cdtAmount);

        vm.expectRevert(abi.encodeWithSelector(StratETHShortBonds.TransactionStale.selector, block.timestamp - 1));
        bonds.bond(user, cdtAmount, 0, block.timestamp - 1); // Deadline in the past
    }

    function testBondInsufficientOutputReverts() public {
        uint256 cdtAmount = 1000 ether;

        cdtToken.approve(address(bonds), cdtAmount);

        uint256 highMinNotionalUnderlyingAmount = 1e24; // Unrealistically high minimum output
        vm.expectRevert(
            abi.encodeWithSelector(
                StratETHShortBonds.InsufficientOutput.selector,
                highMinNotionalUnderlyingAmount,
                (cdtAmount * 1e18) / bonds.strikePrice(cdtAmount)
            )
        );
        bonds.bond(user, cdtAmount, highMinNotionalUnderlyingAmount, block.timestamp + 1 hours);
    }

    function testStrikePrice() public view {
        uint256 amount = 3000e18;

        uint256 stratPrice = (_STRAT_ETH_INITIAL_PRICE * _ETH_USD_INITIAL_PRICE) / 1e18; // 18 DP

        // Expected strike with 2000000 CDT and 1000 STRAT (without scaling and BCV of 1) is
        //   STRAT_PRICE * 1000 * STRAT_PRICE / (2000000 - (3000 / 2))
        // = STRAT_PRICE^2 * 1000 / (2000000 - (3000 / 2))
        // = STRAT_PRICE^2 * 1000 / 1998500
        uint256 expectedStrikePrice = stratPrice * stratPrice / 1998500e18 * 1000e18 / 1e18;
        uint256 calculatedStrikePrice = bonds.strikePrice(amount);
        assertApproxEqAbs(calculatedStrikePrice, expectedStrikePrice, 100000, "Strike price calculation is incorrect");
    }

    function testStrikePrice_priceNotEqual() public {
        uint256 amount = 3000e18;

        // Adjust the STRAT-ETH price to be not 1:1
        stratEthOracle.setBasePerQuote(2e18);

        uint256 stratPrice = (2e18 * _ETH_USD_INITIAL_PRICE) / 1e18; // 18 DP

        // Expected strike with 2000000 CDT and 1000 STRAT (without scaling and BCV of 1) is
        //   STRAT_PRICE * 1000 * STRAT_PRICE / (2000000 - (3000 / 2))
        // = STRAT_PRICE^2 * 1000 / (2000000 - (3000 / 2))
        // = STRAT_PRICE^2 * 1000 / 1998500
        uint256 expectedStrikePrice = stratPrice * stratPrice / 1998500e18 * 1000e18 / 1e18;
        uint256 calculatedStrikePrice = bonds.strikePrice(amount);
        assertApproxEqAbs(calculatedStrikePrice, expectedStrikePrice, 100000, "Strike price calculation is incorrect");
    }

    function testBond() public {
        uint256 startingCdtSupply = cdtToken.totalSupply();
        uint256 cdtAmount = 1000 ether;

        // Calculate the expected underlying amount
        uint256 expectedUnderlyingAmount = (cdtAmount * 1e18) / bonds.strikePrice(cdtAmount);
        assertEq(expectedUnderlyingAmount, 222166666666666666, "Incorrect expected underlying amount");

        cdtToken.approve(address(bonds), cdtAmount);
        bonds.bond(user, cdtAmount, 0, block.timestamp + 1 hours);

        assertEq(cdtToken.totalSupply() + cdtAmount, startingCdtSupply, "CDT not burned");

        // Verify the minted StratOption attributes
        uint256 tokenId = 1; // Assuming this is the first minted option

        // NFT Option properties
        assertEq(stratOption.ownerOf(tokenId), user, "Incorrect owner");
        assertEq(stratOption.strikeAmount(tokenId), 0, "Strike should be 0");
        assertEq(stratOption.notionalUSDAmount(tokenId), 0, "notional USD amount should be 0");
        assertEq(
            stratOption.notionalUnderlyingAmount(tokenId),
            expectedUnderlyingAmount,
            "Incorrect notional underlying amount"
        );
        assertEq(stratOption.notionalUnderlyingAmount(tokenId), stratToken.balanceOf(bondConverter));

        assertEq(stratOption.expiry(tokenId), block.timestamp + (420 * 365 days), "Incorrect expiry");
        assertEq(stratOption.timelock(tokenId), block.timestamp + 6.9 days, "Incorrect timelock");
    }

    function testBondDataInvariants() public {
        cdtToken.approve(address(bonds), 100000 ether);

        for (uint256 i = 0; i < 10; i++) {
            // Bond 1000 cdt
            bonds.bond(user, 1000 ether, 0, block.timestamp + 1 hours);

            if (i == 0) {
                continue;
            }

            assertGt(
                stratOption.notionalUnderlyingAmount(i),
                stratOption.notionalUnderlyingAmount(i + 1),
                "Each subsequent bond should have less notional than the previous"
            );
        }
    }

    function test_bondWithPermit_deadlineIsZero_reverts() public {
        uint256 cdtAmount = 1000 ether;

        // Give permit owner CDT
        cdtToken.transfer(permitOwner, cdtAmount);

        // Get an empty permit approval
        Permit.IPermitApproval memory permitApproval =
            Permit.IPermitApproval({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

        // Expect allowance revert
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(bonds), 0, cdtAmount)
        );

        vm.prank(permitOwner);
        bonds.bondWithPermit(user, cdtAmount, 0, block.timestamp + 1 hours, permitApproval);
    }

    function test_bondWithPermit_deadlineIsZero_spendingApprovalProvided() public {
        uint256 startingCdtSupply = cdtToken.totalSupply();
        uint256 cdtAmount = 1000 ether;

        // Give permit owner CDT
        cdtToken.transfer(permitOwner, cdtAmount);

        // Generate empty permit approval
        Permit.IPermitApproval memory permitApproval =
            Permit.IPermitApproval({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

        // Approve spending of CDT
        vm.prank(permitOwner);
        cdtToken.approve(address(bonds), cdtAmount);

        // Bond with permit
        vm.prank(permitOwner);
        bonds.bondWithPermit(user, cdtAmount, 0, block.timestamp + 1 hours, permitApproval);

        assertEq(cdtToken.totalSupply() + cdtAmount, startingCdtSupply, "CDT not burned");

        // Verify the minted StratOption attributes
        uint256 tokenId = 1; // Assuming this is the first minted option

        // NFT Option properties
        assertEq(stratOption.ownerOf(tokenId), user, "Incorrect owner");
        assertEq(stratOption.strikeAmount(tokenId), 0, "Strike should be 0");
        assertEq(stratOption.notionalUSDAmount(tokenId), 0, "notional USD amount should be 0");
        assertEq(
            stratOption.notionalUnderlyingAmount(tokenId), 222166666666666666, "Incorrect notional underlying amount"
        );
        assertEq(stratOption.expiry(tokenId), block.timestamp + (420 * 365 days), "Incorrect expiry");
        assertEq(stratOption.timelock(tokenId), block.timestamp + 6.9 days, "Incorrect timelock");
        assertEq(stratOption.ownerOf(tokenId), user, "Incorrect owner");
    }

    function test_bondWithPermit_permitDeadlineHasPassed_reverts() public {
        uint256 cdtAmount = 1000 ether;

        // Give permit owner CDT
        cdtToken.transfer(permitOwner, cdtAmount);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner, permitPk, address(bonds), block.timestamp - 1, cdtAmount, cdtToken.DOMAIN_SEPARATOR()
        );

        vm.prank(permitOwner);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, block.timestamp - 1));
        bonds.bondWithPermit(user, cdtAmount, 0, block.timestamp + 1 hours, permitApproval);
    }

    function test_bondWithPermit_differentOwner_reverts() public {
        uint256 cdtAmount = 1000 ether;

        // Give permit owner CDT
        cdtToken.transfer(permitOwner, cdtAmount);

        // Sign a permit approval with a different owner
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("NEW_OWNER");
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            newOwner, newOwnerPk, address(bonds), block.timestamp + 1 days, cdtAmount, cdtToken.DOMAIN_SEPARATOR()
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector,
                0xF9Aad7df470d89159a46c8D6Ba8335B4d81DD288, // Expected signer address, given the parameters
                permitOwner
            )
        );

        vm.prank(permitOwner);
        bonds.bondWithPermit(permitOwner, cdtAmount, 0, block.timestamp + 1 hours, permitApproval);
    }

    function test_bondWithPermit_differentSpender_reverts() public {
        uint256 cdtAmount = 1000 ether;

        // Give permit owner CDT
        cdtToken.transfer(permitOwner, cdtAmount);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner,
            permitPk,
            address(stratOption),
            block.timestamp + 1 days,
            cdtAmount,
            cdtToken.DOMAIN_SEPARATOR()
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector,
                0xC23821808273bA077f3548d26699b83452EE9f7a, // Expected signer address, given the parameters
                permitOwner
            )
        );

        vm.prank(permitOwner);
        bonds.bondWithPermit(permitOwner, cdtAmount, 0, block.timestamp + 1 hours, permitApproval);
    }

    function test_bondWithPermit_invalidSignature_reverts() public {
        uint256 cdtAmount = 1000 ether;

        // Give permit owner CDT
        cdtToken.transfer(permitOwner, cdtAmount);

        // Sign a different message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(permitPk, keccak256("INVALID"));

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval =
            Permit.IPermitApproval({deadline: block.timestamp + 1 days, v: v, r: r, s: s});

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector,
                0x19341391b744a947E3709DBf0194B82C456526a9, // Expected signer address, given the parameters
                permitOwner
            )
        );

        vm.prank(permitOwner);
        bonds.bondWithPermit(permitOwner, cdtAmount, 0, block.timestamp + 1 hours, permitApproval);
    }

    function test_bondWithPermit_callerNotReceipient() public {
        uint256 startingCdtSupply = cdtToken.totalSupply();
        uint256 cdtAmount = 1000 ether;

        // Give permit owner CDT
        cdtToken.transfer(permitOwner, cdtAmount);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner, permitPk, address(bonds), block.timestamp + 1 days, cdtAmount, cdtToken.DOMAIN_SEPARATOR()
        );

        vm.prank(permitOwner);
        bonds.bondWithPermit(user, cdtAmount, 0, block.timestamp + 1 hours, permitApproval);

        assertEq(cdtToken.totalSupply() + cdtAmount, startingCdtSupply, "CDT not burned");

        // Verify the minted StratOption attributes
        uint256 tokenId = 1; // Assuming this is the first minted option

        // NFT Option properties
        assertEq(stratOption.ownerOf(tokenId), user, "Incorrect owner");
        assertEq(stratOption.strikeAmount(tokenId), 0, "Strike should be 0");
        assertEq(stratOption.notionalUSDAmount(tokenId), 0, "notional USD amount should be 0");
        assertEq(
            stratOption.notionalUnderlyingAmount(tokenId), 222166666666666666, "Incorrect notional underlying amount"
        );
        assertEq(stratOption.expiry(tokenId), block.timestamp + (420 * 365 days), "Incorrect expiry");
        assertEq(stratOption.timelock(tokenId), block.timestamp + 6.9 days, "Incorrect timelock");
    }

    function test_bondWithPermit_callerNotRecipient_permitFromRecipient_reverts() public {
        uint256 cdtAmount = 1000 ether;

        // Give permit owner CDT
        cdtToken.transfer(permitOwner, cdtAmount);

        // Sign a permit approval with the recipient
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("NEW_OWNER");
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            newOwner, newOwnerPk, address(bonds), block.timestamp + 1 days, cdtAmount, cdtToken.DOMAIN_SEPARATOR()
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector,
                0xF9Aad7df470d89159a46c8D6Ba8335B4d81DD288, // Expected signer address, given the parameters
                permitOwner
            )
        );

        vm.prank(permitOwner);
        bonds.bondWithPermit(newOwner, cdtAmount, 0, block.timestamp + 1 hours, permitApproval);
    }

    function test_bondWithPermit() public {
        uint256 startingCdtSupply = cdtToken.totalSupply();
        uint256 cdtAmount = 1000 ether;

        // Give permit owner CDT
        cdtToken.transfer(permitOwner, cdtAmount);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner, permitPk, address(bonds), block.timestamp + 1 days, cdtAmount, cdtToken.DOMAIN_SEPARATOR()
        );

        vm.prank(permitOwner);
        bonds.bondWithPermit(permitOwner, cdtAmount, 0, block.timestamp + 1 hours, permitApproval);

        assertEq(cdtToken.totalSupply() + cdtAmount, startingCdtSupply, "CDT not burned");

        // Verify the minted StratOption attributes
        uint256 tokenId = 1; // Assuming this is the first minted option

        // NFT Option properties
        assertEq(stratOption.ownerOf(tokenId), permitOwner, "Incorrect owner");
        assertEq(stratOption.strikeAmount(tokenId), 0, "Strike should be 0");
        assertEq(stratOption.notionalUSDAmount(tokenId), 0, "notional USD amount should be 0");
        assertEq(
            stratOption.notionalUnderlyingAmount(tokenId), 222166666666666666, "Incorrect notional underlying amount"
        );
        assertEq(stratOption.expiry(tokenId), block.timestamp + (420 * 365 days), "Incorrect expiry");
        assertEq(stratOption.timelock(tokenId), block.timestamp + 6.9 days, "Incorrect timelock");
    }

    function test_bondWithPermit_priceNotEqual() public {
        uint256 startingCdtSupply = cdtToken.totalSupply();
        uint256 cdtAmount = 1000 ether;

        // Give permit owner CDT
        cdtToken.transfer(permitOwner, cdtAmount);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner, permitPk, address(bonds), block.timestamp + 1 days, cdtAmount, cdtToken.DOMAIN_SEPARATOR()
        );

        // Adjust the STRAT-ETH price to be not 1:1
        stratEthOracle.setBasePerQuote(2e18);

        // Calculate the expected underlying amount
        uint256 expectedUnderlyingAmount = (cdtAmount * 1e18) / bonds.strikePrice(cdtAmount);

        vm.prank(permitOwner);
        bonds.bondWithPermit(permitOwner, cdtAmount, 0, block.timestamp + 1 hours, permitApproval);

        assertEq(cdtToken.totalSupply() + cdtAmount, startingCdtSupply, "CDT not burned");

        // Verify the minted StratOption attributes
        uint256 tokenId = 1; // Assuming this is the first minted option

        // NFT Option properties
        assertEq(stratOption.ownerOf(tokenId), permitOwner, "Incorrect owner");
        assertEq(stratOption.strikeAmount(tokenId), 0, "Strike should be 0");
        assertEq(stratOption.notionalUSDAmount(tokenId), 0, "notional USD amount should be 0");
        assertEq(
            stratOption.notionalUnderlyingAmount(tokenId),
            expectedUnderlyingAmount,
            "Incorrect notional underlying amount"
        );
        assertEq(stratOption.expiry(tokenId), block.timestamp + (420 * 365 days), "Incorrect expiry");
        assertEq(stratOption.timelock(tokenId), block.timestamp + 6.9 days, "Incorrect timelock");
    }
}
