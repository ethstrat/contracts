// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Uniswap v4 surface used by 005-earn-lp. v4's `Currency`/`IHooks`/`PoolId` types
/// are ABI-identical to `address`/`address`/`bytes32`, so selectors match the deployed contracts.
/// Values copied from v4-core 46c6834 / v4-periphery 9969eec; the ProposeLp fork simulation fails
/// on any mismatch.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev v4-core PoolOperation.sol SwapParams. Used only by 005-earn-lp/Verify.s.sol's swap check.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @dev v4-periphery SlippageCheck.sol. Raised when a mint needs more than amount0Max/amount1Max.
error MaximumAmountExceeded(uint128 maximumAmount, uint128 amountRequested);

/// @dev v4-periphery Actions.sol.
library Actions {
    uint256 internal constant MINT_POSITION = 0x02;
    uint256 internal constant SETTLE_PAIR = 0x0d;
}

interface IPositionManager {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
    function ownerOf(uint256 id) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
    function poolManager() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function permit2() external view returns (address);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

interface IStateView {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function poolManager() external view returns (address);
}

/// @dev Used only by 005-earn-lp/Verify.s.sol's swap check. swap() returns a packed BalanceDelta:
/// amount0 in the upper 128 bits, amount1 in the lower 128 bits.
interface IPoolManagerMinimal {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}
