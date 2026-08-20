// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {esETH} from "../../src/esETH.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";

/// @dev Configurable-rate weETH analogue (copied from esETHTest to keep this file standalone).
contract FuzzMockWeETH is ERC20 {
    uint256 public rate;

    constructor(uint256 initialRate) ERC20("Mock Wrapped eETH", "mweETH") {
        rate = initialRate;
    }

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256) {
        return weETHAmount * rate / 1e18;
    }
}

contract FuzzMintableERC20 is MockERC20 {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev ERC-20 that attempts to reenter `redeem` during `transfer` (the only token outflow).
contract ReentrantRedeemToken is ERC20 {
    esETH public vault;
    bool public attack;

    constructor() ERC20("Reentrant", "REENT") {}

    function setVault(esETH vault_) external {
        vault = vault_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function enableAttack(bool enabled) external {
        attack = enabled;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (attack && address(vault) != address(0) && to != address(vault)) {
            // Swallow the inner revert so a missing reentrancy lock would actually
            // pay out twice. With the lock, this no-ops and the outer redeem completes once.
            try vault.redeem(address(this), 1, to) {} catch {}
        }
        return ok;
    }
}

/// @dev Shared live-like closed TokenConfig: every asset is supported but `isMintable=isRedeemable=false`.
abstract contract esETHClosedConfigBase is Test {
    esETH internal vault;
    MockWETH internal weth;
    FuzzMockWeETH internal weeth;
    FuzzMintableERC20 internal pneth;
    ERC4626Mock internal erc4626;
    ReentrantRedeemToken internal reentrant;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0x17ea5);
    address internal yieldRecv = address(0x71e1d);
    address internal attacker = address(0xA77ac);
    address internal extraMinter = address(0xE171);
    address internal holder = address(0x401d);

    uint256 internal constant SEED = 10_000 ether;

    address[] internal tokens;

    function _deployClosedVault() internal {
        weth = new MockWETH();
        weeth = new FuzzMockWeETH(1.05e18);
        pneth = new FuzzMintableERC20();
        pneth.initialize("Perpetual Note ETH", "pnETH", 18);
        erc4626 = new ERC4626Mock(address(weth));
        reentrant = new ReentrantRedeemToken();

        ITripwireController ctrl = ITripwireController(address(new TripwireController()));
        vm.prank(owner);
        vault = new esETH(owner, address(weth), ctrl, owner);

        vm.startPrank(owner);
        vault.setTokenConfig(address(weth), esETH.TokenType.ERC20, false, false);
        vault.setTokenConfig(address(weeth), esETH.TokenType.WEETH, false, false);
        vault.setTokenConfig(address(pneth), esETH.TokenType.ERC20, false, false);
        vault.setTokenConfig(address(erc4626), esETH.TokenType.ERC4626, false, false);
        vault.setTokenConfig(address(reentrant), esETH.TokenType.ERC20, false, false);
        vault.setTreasuryManager(treasury);
        vault.setYieldReceiver(yieldRecv);
        vault.addMinter(treasury);
        vault.addMinter(extraMinter);
        vm.stopPrank();

        reentrant.setVault(vault);

        tokens.push(address(weth));
        tokens.push(address(weeth));
        tokens.push(address(pneth));
        tokens.push(address(erc4626));
        tokens.push(address(reentrant));

        _fund(treasury);
        _fund(extraMinter);
        _fund(attacker);
        _fund(holder);
        _fund(address(this));
    }

    function _fund(address who) internal {
        vm.deal(who, SEED);
        vm.prank(who);
        weth.deposit{value: SEED / 4}();
        weeth.mint(who, SEED / 4);
        pneth.mint(who, SEED / 4);
        reentrant.mint(who, SEED / 4);

        vm.startPrank(who);
        weth.approve(address(erc4626), type(uint256).max);
        uint256 shares = erc4626.deposit(SEED / 8, who);
        assertGt(shares, 0);
        weth.approve(address(vault), type(uint256).max);
        weeth.approve(address(vault), type(uint256).max);
        pneth.approve(address(vault), type(uint256).max);
        IERC20(address(erc4626)).approve(address(vault), type(uint256).max);
        reentrant.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _seedBackingViaTreasury() internal {
        vm.startPrank(treasury);
        vault.mint(address(weth), 100 ether, treasury);
        vault.mint(address(weeth), 50 ether, treasury);
        vault.mint(address(pneth), 80 ether, treasury);
        uint256 shares = IERC20(address(erc4626)).balanceOf(treasury) / 2;
        vault.mint(address(erc4626), shares, treasury);
        vault.mint(address(reentrant), 20 ether, treasury);
        vm.stopPrank();

        // Attacker and a non-minter holder both receive esETH so they can attempt redeem.
        vm.startPrank(treasury);
        vault.transfer(attacker, vault.balanceOf(treasury) / 3);
        vault.transfer(holder, vault.balanceOf(treasury) / 2);
        vm.stopPrank();
    }

    function _backing(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(address(vault));
    }

    function _assertBackingNotDecreased(address token, uint256 beforeBal) internal view {
        assertGe(_backing(token), beforeBal, "unprivileged caller extracted backing");
    }

    function _assumeUnprivileged(address caller) internal view {
        vm.assume(caller != address(0));
        vm.assume(caller != treasury);
        vm.assume(caller != address(vault));
        vm.assume(caller != address(vm));
        vm.assume(caller != address(weth));
        vm.assume(caller != address(weeth));
        vm.assume(caller != address(pneth));
        vm.assume(caller != address(erc4626));
        vm.assume(caller != address(reentrant));
        vm.assume(uint160(caller) > 0xFF);
    }
}

/**
 * @notice Stateless fuzz proofs for the access-control properties:
 *   1. Closed TokenConfig (`isRedeemable=false`) => only `treasuryManager` can take
 *      backing out, even if the caller holds esETH and even if they are a minter.
 *   2. Only minters can `mint` / `wrapAndMint`.
 *   3. `redeem` is open to any esETH holder when `isRedeemable=true` (not minter-gated).
 *      When `isRedeemable=false`, only `treasuryManager` may redeem that token.
 */
contract esETHAccessControlFuzz is esETHClosedConfigBase {
    function setUp() public {
        _deployClosedVault();
        _seedBackingViaTreasury();
    }

    // -------------------------------------------------------------------------
    // Property 2: only minters can mint / wrapAndMint
    // -------------------------------------------------------------------------

    function testFuzz_nonMinterCannotMint(address caller, uint256 amount, address receiver, uint8 tokenIdx) public {
        _assumeUnprivileged(caller);
        vm.assume(!vault.isMinter(caller));
        amount = bound(amount, 1, 1 ether);
        if (receiver == address(0)) receiver = attacker;
        address token = tokens[tokenIdx % tokens.length];

        _fund(caller);
        vm.prank(caller);
        vm.expectRevert(esETH.NotMinter.selector);
        vault.mint(token, amount, receiver);
    }

    function testFuzz_nonMinterCannotWrapAndMint(address caller, uint256 value, address receiver) public {
        _assumeUnprivileged(caller);
        vm.assume(!vault.isMinter(caller));
        value = bound(value, 1, 1 ether);
        if (receiver == address(0)) receiver = attacker;
        vm.deal(caller, value);

        uint256 wethBefore = _backing(address(weth));
        vm.prank(caller);
        vm.expectRevert(esETH.NotMinter.selector);
        vault.wrapAndMint{value: value}(receiver);
        assertEq(_backing(address(weth)), wethBefore);
        assertEq(address(vault).balance, 0);
    }

    /// @dev Treasury bypass of `isMintable` does not substitute for `isMinter`.
    function testFuzz_treasuryCannotMintUnlessMinter(uint256 amount, address receiver) public {
        amount = bound(amount, 1, 10 ether);
        if (receiver == address(0)) receiver = treasury;

        vm.prank(owner);
        vault.removeMinter(treasury);

        vm.prank(treasury);
        vm.expectRevert(esETH.NotMinter.selector);
        vault.mint(address(weth), amount, receiver);

        vm.deal(treasury, amount);
        vm.prank(treasury);
        vm.expectRevert(esETH.NotMinter.selector);
        vault.wrapAndMint{value: amount}(receiver);
    }

    function testFuzz_extraMinterCannotMintWhenNotMintable(uint256 amount, address receiver, uint8 tokenIdx) public {
        amount = bound(amount, 1, 5 ether);
        if (receiver == address(0)) receiver = extraMinter;
        address token = tokens[tokenIdx % tokens.length];

        uint256 beforeBal = _backing(token);
        vm.prank(extraMinter);
        vm.expectRevert(abi.encodeWithSelector(esETH.TokenNotWhitelistedForMint.selector, token));
        vault.mint(token, amount, receiver);
        assertEq(_backing(token), beforeBal);
    }

    // -------------------------------------------------------------------------
    // Property 1: closed config => only treasuryManager can take backing out
    // -------------------------------------------------------------------------

    function testFuzz_closedConfig_nonTreasuryCannotRedeemEvenWithEsETH(
        address caller,
        uint256 tokenAmount,
        address receiver,
        uint8 tokenIdx
    ) public {
        _assumeUnprivileged(caller);
        tokenAmount = bound(tokenAmount, 1, 20 ether);
        if (receiver == address(0)) receiver = caller;
        address token = tokens[tokenIdx % tokens.length];

        // Give the caller a large esETH balance (and optionally minter status).
        uint256 give = vault.balanceOf(treasury);
        if (give > 0) {
            vm.prank(treasury);
            vault.transfer(caller, give);
        }
        vm.prank(owner);
        vault.addMinter(caller);

        uint256 beforeBal = _backing(token);
        uint256 receiverBefore = IERC20(token).balanceOf(receiver);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(esETH.TokenNotWhitelistedForRedeem.selector, token));
        vault.redeem(token, tokenAmount, receiver);
        assertEq(_backing(token), beforeBal);
        assertEq(IERC20(token).balanceOf(receiver), receiverBefore);
    }

    function testFuzz_closedConfig_attackerHoldingAllEsETHCannotExtract(uint8 tokenIdx, uint256 tokenAmount) public {
        tokenAmount = bound(tokenAmount, 1, 5 ether);
        address token = tokens[tokenIdx % tokens.length];

        // Move every wei of esETH to the attacker (including yield receiver / extra minter).
        _drainEsETHTo(attacker);
        vm.prank(owner);
        vault.addMinter(attacker);

        uint256[5] memory beforeBals = _allBacking();
        uint256 attackerWeth = weth.balanceOf(attacker);
        uint256 attackerWeeth = weeth.balanceOf(attacker);
        uint256 attackerPneth = pneth.balanceOf(attacker);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(esETH.TokenNotWhitelistedForRedeem.selector, token));
        vault.redeem(token, tokenAmount, attacker);

        _assertAllBackingUnchanged(beforeBals);
        assertEq(weth.balanceOf(attacker), attackerWeth);
        assertEq(weeth.balanceOf(attacker), attackerWeeth);
        assertEq(pneth.balanceOf(attacker), attackerPneth);
    }

    function testFuzz_closedConfig_rawCalldataCannotExtractBacking(address caller, bytes calldata data) public {
        _assumeUnprivileged(caller);
        _fund(caller);

        uint256 give = vault.balanceOf(treasury);
        if (give > 1) {
            vm.prank(treasury);
            vault.transfer(caller, give / 2);
        }
        vm.prank(owner);
        vault.addMinter(caller);
        vm.deal(caller, 10 ether);

        uint256[5] memory beforeBals = _allBacking();
        uint256 ethBefore = address(vault).balance;

        vm.prank(caller);
        (bool ok,) = address(vault).call{value: 0}(data);
        ok; // success is allowed only if it cannot decrease backing

        _assertAllBackingUnchangedOrIncreased(beforeBals);
        assertEq(address(vault).balance, ethBefore);
    }

    function testFuzz_closedConfig_knownSelectorsCannotExtract(
        address caller,
        uint8 selectorIdx,
        uint256 amount,
        address receiver,
        uint8 tokenIdx
    ) public {
        _assumeUnprivileged(caller);
        amount = bound(amount, 0, 20 ether);
        address token = tokens[tokenIdx % tokens.length];
        if (receiver == address(0)) receiver = caller;

        _fund(caller);
        uint256 give = vault.balanceOf(treasury);
        if (give > 1) {
            vm.prank(treasury);
            vault.transfer(caller, give / 2);
        }
        vm.prank(owner);
        vault.addMinter(caller);
        vm.deal(caller, 5 ether);

        uint256[5] memory beforeBals = _allBacking();

        bytes memory payload;
        uint8 sel = selectorIdx % 12;
        if (sel == 0) {
            payload = abi.encodeWithSelector(esETH.mint.selector, token, amount == 0 ? 1 : amount, receiver);
        } else if (sel == 1) {
            payload = abi.encodeWithSelector(esETH.wrapAndMint.selector, receiver);
        } else if (sel == 2) {
            payload = abi.encodeWithSelector(esETH.redeem.selector, token, amount == 0 ? 1 : amount, receiver);
        } else if (sel == 3) {
            payload = abi.encodeWithSelector(esETH.harvestYield.selector, tokens);
        } else if (sel == 4) {
            payload = abi.encodeWithSelector(esETH.burnExcess.selector, tokens);
        } else if (sel == 5) {
            payload = abi.encodeWithSelector(vault.transfer.selector, receiver, amount);
        } else if (sel == 6) {
            payload = abi.encodeWithSelector(vault.approve.selector, receiver, amount);
        } else if (sel == 7) {
            payload = abi.encodeWithSelector(vault.transferFrom.selector, attacker, receiver, amount);
        } else if (sel == 8) {
            payload = abi.encodeWithSelector(esETH.addMinter.selector, caller);
        } else if (sel == 9) {
            payload = abi.encodeWithSelector(esETH.setTokenConfig.selector, token, uint8(1), true, true);
        } else if (sel == 10) {
            payload = abi.encodeWithSelector(esETH.setTreasuryManager.selector, caller);
        } else {
            payload = abi.encodeWithSelector(esETH.setYieldReceiver.selector, caller);
        }

        vm.prank(caller);
        if (sel == 1) {
            (bool ok,) = address(vault).call{value: bound(amount, 0, 1 ether)}(payload);
            ok;
        } else {
            (bool ok,) = address(vault).call(payload);
            ok;
        }

        _assertAllBackingUnchangedOrIncreased(beforeBals);
        assertEq(address(vault).balance, 0);
    }

    /// @dev Intended design: any esETH holder may redeem a token with `isRedeemable=true`,
    ///      including a non-minter. Mint remains closed (`isMintable=false`).
    function test_redeemableToken_nonMinterHolderCanRedeem() public {
        vm.prank(owner);
        vault.setTokenConfig(address(weth), esETH.TokenType.ERC20, false, true);

        assertEq(vault.isMinter(holder), false);
        uint256 holderWethBefore = weth.balanceOf(holder);
        uint256 redeemAmt = 1 ether;
        vm.prank(holder);
        vault.redeem(address(weth), redeemAmt, holder);
        assertEq(weth.balanceOf(holder), holderWethBefore + redeemAmt);
    }

    function testFuzz_redeemableToken_anyEsETHHolderCanRedeem(address caller, uint256 redeemAmt) public {
        _assumeUnprivileged(caller);
        vm.assume(!vault.isMinter(caller));
        redeemAmt = bound(redeemAmt, 1, 5 ether);

        vm.prank(owner);
        vault.setTokenConfig(address(weth), esETH.TokenType.ERC20, false, true);

        uint256 give = vault.balanceOf(treasury);
        vm.assume(give > redeemAmt + 1);
        vm.prank(treasury);
        vault.transfer(caller, give);

        uint256 wethBefore = weth.balanceOf(caller);
        uint256 vaultBefore = _backing(address(weth));
        vm.prank(caller);
        vault.redeem(address(weth), redeemAmt, caller);
        assertEq(weth.balanceOf(caller), wethBefore + redeemAmt);
        assertEq(_backing(address(weth)), vaultBefore - redeemAmt);
    }

    function test_treasuryCanRedeemWhenClosed() public {
        uint256 before = _backing(address(weth));
        vm.prank(treasury);
        vault.redeem(address(weth), 1 ether, treasury);
        assertEq(_backing(address(weth)), before - 1 ether);
    }

    function test_reentrantTokenCannotDoubleExtract() public {
        reentrant.enableAttack(true);
        uint256 vaultBefore = _backing(address(reentrant));
        uint256 attackerBefore = reentrant.balanceOf(attacker);
        uint256 redeemAmt = 1 ether;

        vm.prank(treasury);
        vault.redeem(address(reentrant), redeemAmt, attacker);

        // Inner reenter is attempted with try/catch; the guard must prevent a second payout.
        assertEq(reentrant.balanceOf(attacker), attackerBefore + redeemAmt);
        assertEq(_backing(address(reentrant)), vaultBefore - redeemAmt);
    }

    function test_harvestYieldDoesNotMoveBacking() public {
        weth.deposit{value: 5 ether}();
        weth.transfer(address(vault), 5 ether);
        uint256 before = _backing(address(weth));
        vault.harvestYield(tokens);
        assertEq(_backing(address(weth)), before);
        assertGt(vault.balanceOf(yieldRecv), 0);
        // Yield receiver still cannot extract under closed config.
        vm.prank(yieldRecv);
        vm.expectRevert(abi.encodeWithSelector(esETH.TokenNotWhitelistedForRedeem.selector, address(weth)));
        vault.redeem(address(weth), 1, yieldRecv);
    }

    function _drainEsETHTo(address to) internal {
        address[4] memory holders = [treasury, extraMinter, holder, yieldRecv];
        for (uint256 i; i < holders.length; ++i) {
            uint256 bal = vault.balanceOf(holders[i]);
            if (bal > 0) {
                vm.prank(holders[i]);
                vault.transfer(to, bal);
            }
        }
    }

    function _allBacking() internal view returns (uint256[5] memory bals) {
        for (uint256 i; i < 5; ++i) {
            bals[i] = _backing(tokens[i]);
        }
    }

    function _assertAllBackingUnchanged(uint256[5] memory beforeBals) internal view {
        for (uint256 i; i < 5; ++i) {
            assertEq(_backing(tokens[i]), beforeBals[i]);
        }
    }

    function _assertAllBackingUnchangedOrIncreased(uint256[5] memory beforeBals) internal view {
        for (uint256 i; i < 5; ++i) {
            assertGe(_backing(tokens[i]), beforeBals[i]);
        }
    }
}

/// @dev Stateful handler. Owner admin is intentionally omitted so TokenConfig stays closed.
contract esETHClosedVaultHandler is Test {
    esETH public vault;
    MockWETH public weth;
    FuzzMockWeETH public weeth;
    FuzzMintableERC20 public pneth;
    ERC4626Mock public erc4626;

    address public owner;
    address public treasury;
    address public attacker;
    address public extraMinter;
    address public holder;
    address public yieldRecv;

    address[] public tokens;

    uint256 public ghostNonTreasuryExtracts;
    uint256 public ghostNonMinterMints;
    uint256 public ghostCalls;

    constructor(
        esETH vault_,
        MockWETH weth_,
        FuzzMockWeETH weeth_,
        FuzzMintableERC20 pneth_,
        ERC4626Mock erc4626_,
        address owner_,
        address treasury_,
        address attacker_,
        address extraMinter_,
        address holder_,
        address yieldRecv_
    ) {
        vault = vault_;
        weth = weth_;
        weeth = weeth_;
        pneth = pneth_;
        erc4626 = erc4626_;
        owner = owner_;
        treasury = treasury_;
        attacker = attacker_;
        extraMinter = extraMinter_;
        holder = holder_;
        yieldRecv = yieldRecv_;

        tokens.push(address(weth_));
        tokens.push(address(weeth_));
        tokens.push(address(pneth_));
        tokens.push(address(erc4626_));
    }

    function attackerMint(uint256 tokenIdx, uint256 amount) external {
        ghostCalls++;
        address token = tokens[tokenIdx % tokens.length];
        amount = bound(amount, 1, 5 ether);
        uint256 beforeBal = IERC20(token).balanceOf(address(vault));
        vm.prank(attacker);
        try vault.mint(token, amount, attacker) {
            ghostNonMinterMints += vault.isMinter(attacker) ? 0 : 1;
            // Closed config: even a minter who is not treasury must not succeed.
            if (attacker != treasury) {
                revert("attacker mint succeeded under closed config");
            }
        } catch {
            assertEq(IERC20(token).balanceOf(address(vault)), beforeBal);
        }
    }

    function extraMinterMint(uint256 tokenIdx, uint256 amount) external {
        ghostCalls++;
        address token = tokens[tokenIdx % tokens.length];
        amount = bound(amount, 1, 5 ether);
        uint256 beforeBal = IERC20(token).balanceOf(address(vault));
        vm.prank(extraMinter);
        try vault.mint(token, amount, extraMinter) {
            revert("extra minter minted under closed config");
        } catch {
            assertEq(IERC20(token).balanceOf(address(vault)), beforeBal);
        }
    }

    function attackerWrapAndMint(uint256 value, address receiver) external {
        ghostCalls++;
        value = bound(value, 1, 2 ether);
        if (receiver == address(0)) receiver = attacker;
        vm.deal(attacker, value);
        uint256 beforeBal = weth.balanceOf(address(vault));
        vm.prank(attacker);
        try vault.wrapAndMint{value: value}(receiver) {
            revert("attacker wrapAndMint succeeded under closed config");
        } catch {
            assertEq(weth.balanceOf(address(vault)), beforeBal);
            assertEq(address(vault).balance, 0);
        }
    }

    function attackerRedeem(uint256 tokenIdx, uint256 amount, address receiver) external {
        ghostCalls++;
        address token = tokens[tokenIdx % tokens.length];
        amount = bound(amount, 1, 5 ether);
        if (receiver == address(0)) receiver = attacker;
        uint256 beforeBal = IERC20(token).balanceOf(address(vault));
        uint256 recvBefore = IERC20(token).balanceOf(receiver);
        vm.prank(attacker);
        try vault.redeem(token, amount, receiver) {
            ghostNonTreasuryExtracts++;
            revert("attacker redeemed under closed config");
        } catch {
            assertEq(IERC20(token).balanceOf(address(vault)), beforeBal);
            assertEq(IERC20(token).balanceOf(receiver), recvBefore);
        }
    }

    function holderRedeem(uint256 tokenIdx, uint256 amount) external {
        ghostCalls++;
        address token = tokens[tokenIdx % tokens.length];
        amount = bound(amount, 1, 5 ether);
        uint256 beforeBal = IERC20(token).balanceOf(address(vault));
        vm.prank(holder);
        try vault.redeem(token, amount, holder) {
            ghostNonTreasuryExtracts++;
            revert("non-minter holder redeemed under closed config");
        } catch {
            assertEq(IERC20(token).balanceOf(address(vault)), beforeBal);
        }
    }

    function extraMinterRedeem(uint256 tokenIdx, uint256 amount) external {
        ghostCalls++;
        address token = tokens[tokenIdx % tokens.length];
        amount = bound(amount, 1, 5 ether);
        uint256 beforeBal = IERC20(token).balanceOf(address(vault));
        vm.prank(extraMinter);
        try vault.redeem(token, amount, extraMinter) {
            ghostNonTreasuryExtracts++;
            revert("minter (non-treasury) redeemed under closed config");
        } catch {
            assertEq(IERC20(token).balanceOf(address(vault)), beforeBal);
        }
    }

    function attackerHarvest() external {
        ghostCalls++;
        uint256[4] memory beforeBals;
        for (uint256 i; i < 4; ++i) {
            beforeBals[i] = IERC20(tokens[i]).balanceOf(address(vault));
        }
        vm.prank(attacker);
        vault.harvestYield(tokens);
        for (uint256 i; i < 4; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(vault)), beforeBals[i]);
        }
    }

    function attackerBurnExcess() external {
        ghostCalls++;
        uint256[4] memory beforeBals;
        for (uint256 i; i < 4; ++i) {
            beforeBals[i] = IERC20(tokens[i]).balanceOf(address(vault));
        }
        vm.prank(attacker);
        try vault.burnExcess(tokens) {} catch {}
        for (uint256 i; i < 4; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(vault)), beforeBals[i]);
        }
    }

    function attackerDonate(uint256 tokenIdx, uint256 amount) external {
        ghostCalls++;
        address token = tokens[tokenIdx % tokens.length];
        amount = bound(amount, 1, 2 ether);
        uint256 attackerBal = IERC20(token).balanceOf(attacker);
        if (attackerBal < amount) return;
        vm.prank(attacker);
        IERC20(token).transfer(address(vault), amount);
    }

    function attackerTransferEsETH(uint256 amount, address to) external {
        ghostCalls++;
        if (to == address(0)) to = holder;
        amount = bound(amount, 0, vault.balanceOf(attacker));
        if (amount == 0) return;
        vm.prank(attacker);
        vault.transfer(to, amount);
    }

    function weethRateMove(uint256 newRate) external {
        ghostCalls++;
        newRate = bound(newRate, 0.5e18, 2e18);
        weeth.setRate(newRate);
    }

    function treasuryMint(uint256 tokenIdx, uint256 amount, address receiver) external {
        ghostCalls++;
        address token = tokens[tokenIdx % tokens.length];
        amount = bound(amount, 1, 5 ether);
        if (receiver == address(0)) receiver = treasury;
        uint256 treBal = IERC20(token).balanceOf(treasury);
        if (treBal < amount) return;
        vm.prank(treasury);
        try vault.mint(token, amount, receiver) {} catch {}
    }

    function treasuryRedeem(uint256 tokenIdx, uint256 amount, address receiver) external {
        ghostCalls++;
        address token = tokens[tokenIdx % tokens.length];
        uint256 vaultBal = IERC20(token).balanceOf(address(vault));
        if (vaultBal < 2) return;
        amount = bound(amount, 1, vaultBal / 2);
        if (receiver == address(0)) receiver = treasury;
        vm.prank(treasury);
        try vault.redeem(token, amount, receiver) {} catch {}
    }

    function treasuryWrapAndMint(uint256 value, address receiver) external {
        ghostCalls++;
        value = bound(value, 1, 2 ether);
        if (receiver == address(0)) receiver = treasury;
        vm.deal(treasury, value);
        vm.prank(treasury);
        try vault.wrapAndMint{value: value}(receiver) {} catch {}
    }
}

contract esETHClosedVaultInvariants is esETHClosedConfigBase {
    esETHClosedVaultHandler internal handler;

    function setUp() public {
        _deployClosedVault();
        _seedBackingViaTreasury();

        handler = new esETHClosedVaultHandler(
            vault, weth, weeth, pneth, erc4626, owner, treasury, attacker, extraMinter, holder, yieldRecv
        );

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = esETHClosedVaultHandler.attackerMint.selector;
        selectors[1] = esETHClosedVaultHandler.extraMinterMint.selector;
        selectors[2] = esETHClosedVaultHandler.attackerWrapAndMint.selector;
        selectors[3] = esETHClosedVaultHandler.attackerRedeem.selector;
        selectors[4] = esETHClosedVaultHandler.holderRedeem.selector;
        selectors[5] = esETHClosedVaultHandler.extraMinterRedeem.selector;
        selectors[6] = esETHClosedVaultHandler.attackerHarvest.selector;
        selectors[7] = esETHClosedVaultHandler.attackerBurnExcess.selector;
        selectors[8] = esETHClosedVaultHandler.attackerDonate.selector;
        selectors[9] = esETHClosedVaultHandler.attackerTransferEsETH.selector;
        selectors[10] = esETHClosedVaultHandler.weethRateMove.selector;
        selectors[11] = esETHClosedVaultHandler.treasuryMint.selector;
        selectors[12] = esETHClosedVaultHandler.treasuryRedeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INV-CLOSED-001: no successful non-treasury redeem/extract was ever recorded.
    function invariant_nonTreasuryNeverExtractsBacking() public view {
        assertEq(handler.ghostNonTreasuryExtracts(), 0, "non-treasury extracted backing");
    }

    /// @notice INV-CLOSED-002: mint never succeeded for a non-minter.
    function invariant_nonMinterNeverMints() public view {
        assertEq(handler.ghostNonMinterMints(), 0, "non-minter minted");
    }

    /// @notice INV-CLOSED-003: flags stay closed (handler has no owner admin).
    function invariant_tokenConfigStaysClosed() public view {
        for (uint256 i; i < tokens.length; ++i) {
            (, bool isMintable, bool isRedeemable,) = vault.tokenConfigs(tokens[i]);
            assertFalse(isMintable, "isMintable flipped");
            assertFalse(isRedeemable, "isRedeemable flipped");
        }
    }

    function invariant_noEthStuckFromFailedWrap() public view {
        assertEq(address(vault).balance, 0);
    }

    function invariant_treasuryManagerUnchanged() public view {
        assertEq(vault.treasuryManager(), treasury);
    }
}
