// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    ProposeCompensation
} from "../../script/deployments/1/007-earn-espn-staker-compensation/ProposeCompensation.s.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

interface IArrakisV2Helper {
    function totalUnderlying(address vault) external view returns (uint256 amount0, uint256 amount1);
}

/// @notice Fork test proving the hardcoded AMOUNTs in 007 ProposeCompensation._recipients() are
/// correct: recomputes each recipient's formula from live on-chain state at the snapshot block
/// (26043909) and asserts it matches, and proves no holder is missing from either source list.
/// Run with: FOUNDRY_PROFILE=integration forge test --match-contract EarnEspnStakerCompensationForkTest \
///   --fork-url "$FORK_URL" -vv   (see package.json's test:integration for the default FORK_URL).
contract EarnEspnStakerCompensationForkTest is Test {
    uint256 internal constant FORK_BLOCK = 26043909;

    address internal constant SESPN_LP = 0xcD65F0b6E31e44225330DB8622a9e5307DDC6c1C;
    address internal constant ARRAKIS_VAULT = 0x2F63AE2184D876f156b9eF21f488d4E6B442FaD7;
    address internal constant ARRAKIS_HELPER = 0x89E4bE1F999E3a58D16096FBe405Fc2a1d7F07D6;
    address internal constant ESPN = 0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE;

    ProposeCompensation internal script_;

    function setUp() public {
        vm.rollFork(FORK_BLOCK);
        require(block.chainid == 1, "Must be on mainnet fork");
        script_ = new ProposeCompensation();
    }

    function testFork_recipientAmountsMatchFormula() public view {
        (address[] memory recipients, uint256[] memory amounts) = script_._recipients();
        assertEq(recipients.length, 10, "expected 10 recipients");
        assertEq(amounts.length, 10, "expected 10 amounts");

        uint256 sespnlpTotalAssets = IERC4626(SESPN_LP).totalAssets();
        uint256 sespnlpTotalSupply = IERC4626(SESPN_LP).totalSupply();
        uint256 arrakisTotalSupply = IERC20(ARRAKIS_VAULT).totalSupply();
        (uint256 arrakisUnderlyingEspn,) = IArrakisV2Helper(ARRAKIS_HELPER).totalUnderlying(ARRAKIS_VAULT);
        uint256 espnTotalAssets = IERC4626(ESPN).totalAssets();
        uint256 espnTotalSupply = IERC4626(ESPN).totalSupply();

        uint256 sespnlpBalanceSum;
        uint256 arrakisDirectSum;

        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 sespnlpBal = IERC20(SESPN_LP).balanceOf(recipients[i]);
            uint256 directArrakisShares = IERC20(ARRAKIS_VAULT).balanceOf(recipients[i]);
            sespnlpBalanceSum += sespnlpBal;
            arrakisDirectSum += directArrakisShares;

            uint256 sespnlpComponent = sespnlpBal * sespnlpTotalAssets / sespnlpTotalSupply;
            uint256 arrakisShares = sespnlpComponent + directArrakisShares;
            uint256 espnEq = arrakisShares * arrakisUnderlyingEspn / arrakisTotalSupply;
            uint256 expected = espnEq * espnTotalAssets / (espnTotalSupply * 100);

            assertEq(amounts[i], expected, "AMOUNT mismatch vs. recomputed formula");
        }

        // Proves no sESPN-LP holder is missing from the hardcoded recipient list.
        assertEq(sespnlpBalanceSum, sespnlpTotalSupply, "sESPN-LP balances don't sum to its totalSupply");

        // Proves no direct Arrakis holder is missing: sESPN-LP's own Arrakis shares plus the 4
        // direct holders account for all of Arrakis's totalSupply.
        uint256 sespnlpArrakisBalance = IERC20(ARRAKIS_VAULT).balanceOf(SESPN_LP);
        assertEq(
            sespnlpArrakisBalance + arrakisDirectSum, arrakisTotalSupply, "Arrakis balances don't sum to totalSupply"
        );
    }
}
