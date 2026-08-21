// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {ISeaportMinimal} from "./interfaces/ISeaportMinimal.sol";
import {BuildOrderLib} from "./BuildOrderLib.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {HoldersLib} from "../lib/HoldersLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";

/// @notice Builds the Track A Seaport order and emits a Safe batch. Never broadcasts — the
/// offerer is the treasury Safe. See Task 4 Step 20.
///
/// Config is read into private state (rather than threaded through function arguments/locals) to
/// keep `_buildOrder` under the via-ir Yul stack-depth limit — the derivation, pre-conditions,
/// informational capacity log, order construction, hash and run-book text together touch too many
/// live values for one function's locals alone.
contract BuildOrder is Script {
    IERC4626 private espn;
    IERC20 private usds;
    ISeaportMinimal private seaport;
    address private treasury;
    uint256 private fillGrid;
    uint256 private redemptionRatio;
    uint256 private orderStartTime;
    uint256 private orderEndTime;
    string private orderSalt;

    function run() external virtual {
        address redemptionToken = ConfigLib.addr("deploymentAddresses.json", ".espn-redemption-token");
        string memory holdersFile = vm.envString("HOLDERS_FILE");

        (ISeaportMinimal.OrderParameters memory orderParams,, uint256 usdsOfferOut,,) =
            _buildOrder(redemptionToken, holdersFile);

        ISeaportMinimal.Order[] memory orders = new ISeaportMinimal.Order[](1);
        orders[0] = ISeaportMinimal.Order({parameters: orderParams, signature: ""});

        SafeBatchLib.Tx[] memory txs = new SafeBatchLib.Tx[](2);
        txs[0] = SafeBatchLib.Tx({
            to: address(usds), data: abi.encodeCall(IERC20.approve, (address(seaport), usdsOfferOut))
        });
        txs[1] = SafeBatchLib.Tx({to: address(seaport), data: abi.encodeCall(ISeaportMinimal.validate, (orders))});

        SafeBatchLib.write(
            treasury,
            "003-espn-redemption",
            1,
            "ESPNv3 Track A: approve + validate redemption order",
            "USDS.approve(Seaport, usdsOffer) then Seaport.validate([order])",
            txs
        );
    }

    /// @dev Shared with `Verify.s.sol`, which calls this under `vm.startPrank(treasury)`. Derives
    /// amounts, runs every pre-condition, constructs the order and computes its hash. Never calls
    /// `USDS.approve` / `Seaport.validate` itself — this function runs unpranked from `run()` too,
    /// where the caller is not the treasury Safe and cannot make those calls for real.
    function _buildOrder(address redemptionToken, string memory holdersFile)
        internal
        returns (
            ISeaportMinimal.OrderParameters memory orderParams,
            bytes32 orderHash,
            uint256 usdsOffer,
            uint256 espnAsk,
            uint256 redemptionAsk
        )
    {
        _loadConfig();

        uint256 navPerEspn;
        (usdsOffer, espnAsk, redemptionAsk, navPerEspn) = _deriveAndCheckPreconditions(redemptionToken);

        _logCapacity(redemptionToken, holdersFile, navPerEspn);

        orderParams = _constructOrder(redemptionToken, usdsOffer, espnAsk, redemptionAsk);
        orderHash = _hashOrder(orderParams);

        _logRunBook(usdsOffer, espnAsk, redemptionAsk);
    }

    function _loadConfig() private {
        espn = IERC4626(ConfigLib.addr("externalAddresses.json", ".eth-strategy.espn"));
        usds = IERC20(ConfigLib.addr("externalAddresses.json", ".sky-money.USDS"));
        seaport = ISeaportMinimal(ConfigLib.addr("externalAddresses.json", ".opensea.seaport"));
        treasury = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        fillGrid = ConfigLib.num("settings.json", ".espnv3.fillGrid");
        redemptionRatio = ConfigLib.num("settings.json", ".espnv3.redemptionRatio");
        orderStartTime = ConfigLib.num("settings.json", ".espnv3.orderStartTime");
        orderEndTime = ConfigLib.num("settings.json", ".espnv3.orderEndTime");
        orderSalt = ConfigLib.str("settings.json", ".espnv3.orderSalt");
    }

    /// @dev Derivation plus every Step 20 item-3 hard-revert pre-condition.
    function _deriveAndCheckPreconditions(address redemptionToken)
        private
        view
        returns (uint256 usdsOffer, uint256 espnAsk, uint256 redemptionAsk, uint256 navPerEspn)
    {
        uint256 targetRedemptionUsd = ConfigLib.num("settings.json", ".espnv3.targetRedemptionUsd");
        (usdsOffer, espnAsk, redemptionAsk, navPerEspn) = BuildOrderLib.deriveAmounts(
            targetRedemptionUsd, redemptionRatio, fillGrid, espn.totalAssets(), espn.totalSupply()
        );

        require(usds.balanceOf(treasury) >= usdsOffer, "BuildOrder: treasury USDS balance too low");
        require(
            usds.decimals() == 18 && espn.decimals() == 18 && IERC20(redemptionToken).decimals() == 18,
            "BuildOrder: a token is not 18 decimals"
        );
        require(espn.asset() == address(usds), "BuildOrder: ESPN.asset() != USDS");
        require(treasury.code.length > 0, "BuildOrder: treasury has no code");
        uint256 expectedSeaportCounter = ConfigLib.num("settings.json", ".espnv3.expectedSeaportCounter");
        require(seaport.getCounter(treasury) == expectedSeaportCounter, "BuildOrder: Seaport counter mismatch");
        require(
            usdsOffer % fillGrid == 0 && espnAsk % fillGrid == 0 && redemptionAsk % fillGrid == 0,
            "BuildOrder: amounts not grid-aligned"
        );
        require(block.timestamp < orderStartTime, "BuildOrder: orderStartTime already passed");
        require(orderStartTime < orderEndTime, "BuildOrder: orderStartTime >= orderEndTime");
    }

    /// @dev Logged, not reverted — two capacity figures so the signer sees the realistic cap, not
    /// just the theoretical one (Step 20 item 3).
    function _logCapacity(address redemptionToken, string memory holdersFile, uint256 navPerEspn) private view {
        HoldersLib.Snapshot memory snapshot = HoldersLib.load(holdersFile);
        address[] memory excludedAddresses = ConfigLib.addrArray("settings.json", ".espnv3.excludedAddresses");
        IERC20 redemption = IERC20(redemptionToken);

        uint256 usableRedemption = redemption.totalSupply() - redemption.balanceOf(treasury);
        for (uint256 i = 0; i < excludedAddresses.length; i++) {
            usableRedemption -= redemption.balanceOf(excludedAddresses[i]);
        }
        uint256 reachableRedemption = usableRedemption;
        for (uint256 i = 0; i < snapshot.holders.length; i++) {
            if (snapshot.holders[i].isContract) {
                reachableRedemption -= redemption.balanceOf(snapshot.holders[i].addr);
            }
        }

        console2.log(
            "usable capacity (ex-treasury, ex-excluded), USDS:", usableRedemption / redemptionRatio * navPerEspn / 1e18
        );
        console2.log(
            "reachable capacity (ex-contract holders too), USDS:",
            reachableRedemption / redemptionRatio * navPerEspn / 1e18
        );
    }

    function _constructOrder(address redemptionToken, uint256 usdsOffer, uint256 espnAsk, uint256 redemptionAsk)
        private
        view
        returns (ISeaportMinimal.OrderParameters memory)
    {
        BuildOrderLib.TokenAndAmount[] memory offers = new BuildOrderLib.TokenAndAmount[](1);
        offers[0] = BuildOrderLib.TokenAndAmount({token: address(usds), amount: usdsOffer});
        BuildOrderLib.TokenAndAmount[] memory asks = new BuildOrderLib.TokenAndAmount[](2);
        asks[0] = BuildOrderLib.TokenAndAmount({token: redemptionToken, amount: redemptionAsk});
        asks[1] = BuildOrderLib.TokenAndAmount({token: address(espn), amount: espnAsk});

        return BuildOrderLib.constructOrderParams(
            treasury,
            BuildOrderLib.Order({
                offers: offers,
                asks: asks,
                askRecipient: treasury,
                startTimestamp: orderStartTime,
                endTimestamp: orderEndTime,
                salt: bytes(orderSalt)
            })
        );
    }

    function _hashOrder(ISeaportMinimal.OrderParameters memory orderParams) private view returns (bytes32) {
        ISeaportMinimal.OrderComponents memory components = ISeaportMinimal.OrderComponents({
            offerer: orderParams.offerer,
            zone: orderParams.zone,
            offer: orderParams.offer,
            consideration: orderParams.consideration,
            orderType: orderParams.orderType,
            startTime: orderParams.startTime,
            endTime: orderParams.endTime,
            zoneHash: orderParams.zoneHash,
            salt: orderParams.salt,
            conduitKey: orderParams.conduitKey,
            counter: seaport.getCounter(treasury)
        });
        bytes32 orderHash = seaport.getOrderHash(components);
        console2.log("order hash:");
        console2.logBytes32(orderHash);
        return orderHash;
    }

    /// @dev The holder run-book block (item 6) — there is no UI, so this text is the entire
    /// holder-facing interface. REDEMPTION binds, not ESPN — matches `BuildOrderLib.deriveNumerator`
    /// exactly; do not hand-roll a different formula here.
    function _logRunBook(uint256 usdsOffer, uint256 espnAsk, uint256 redemptionAsk) private view {
        console2.log("--- holder run-book (this is the entire holder-facing interface) ---");
        console2.log("denominator =", fillGrid);
        console2.log("numerator   = min( floor(yourEspnBalance * denominator / espnAsk),");
        console2.log("                   floor(yourRedemptionBalance * denominator / redemptionAsk) )");
        console2.log("            = in practice, floor(yourEspnBalance * denominator / redemptionAsk)");
        console2.log("              -> you can redeem at most 20% of your ESPN");
        console2.log("espnAsk       =", espnAsk);
        console2.log("redemptionAsk =", redemptionAsk);
        console2.log("usdsOffer     =", usdsOffer);
        console2.log("you pay     : espnAsk * n / denominator ESPN  and  redemptionAsk * n / denominator REDEMPTION");
        console2.log("you receive : usdsOffer * n / denominator USDS");
        console2.log("approve Seaport for both amounts first:", address(seaport));
    }
}
