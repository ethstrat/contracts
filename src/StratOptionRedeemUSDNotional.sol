// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {StratOption} from "./StratOption.sol";
import {IERC20, IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {IOracle} from "./interfaces/IOracle.sol";

interface Treasury {
    function withdraw(uint256 amount) external;
    function total() external view returns (uint256);
}

contract StratOptionRedeemUSDNotional {
    IERC20MintableBurnable public immutable cdtToken;
    IERC20 public immutable stratToken;
    Treasury public immutable treasury;
    IOracle public immutable ethUsdOracle;
    StratOption public immutable stratOption;

    error NotOwnerOrApproved(address account, uint256 tokenId);
    error TimelockActive(address account, uint256 tokenId);
    error OptionUnexpired(address account, uint256 tokenId);

    // TODO(nap): Events

    /**
     * @param _cdtToken The CDT token
     * @param _stratOption The STRAT option
     * @param _treasury STRAT treasury
     * @param _ethUsdOracle The ETH/USD oracle
     * @param _stratOption The STRAT option
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _treasury,
        address _ethUsdOracle,
        address _stratOption
    ) {
        cdtToken = IERC20MintableBurnable(_cdtToken);
        stratToken = IERC20(_stratToken);
        treasury = Treasury(_treasury);
        ethUsdOracle = IOracle(_ethUsdOracle);
        stratOption = StratOption(_stratOption);
    }

    function redeemCdtForUsdNotional(uint256 tokenId) external {
        if (stratOption.timelock(tokenId) > block.timestamp) revert TimelockActive(msg.sender, tokenId);
        if (stratOption.expiry(tokenId) > block.timestamp) revert OptionUnexpired(msg.sender, tokenId);

        uint256 notionalUSDAmount = stratOption.notionalUSDAmount(tokenId);
        uint256 totalDebt = cdtToken.totalSupply();
        uint256 ethPriceUSD = ethUsdOracle.price();
        uint256 oracleScale = 10 ** ethUsdOracle.quoteTokenDecimals();
        uint256 treasuryInUSD = treasury.total() * ethPriceUSD / oracleScale;

        cdtToken.burnFrom(msg.sender, notionalUSDAmount);
        stratOption.burn(tokenId);

        if (treasuryInUSD > cdtToken.totalSupply()) {
            treasury.withdraw(notionalUSDAmount * oracleScale / ethPriceUSD);
        } else {
            treasury.withdraw(notionalUSDAmount * treasuryInUSD / totalDebt);
        }
    }
}
