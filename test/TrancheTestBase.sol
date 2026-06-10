// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

import {TrancheHook} from "../src/TrancheHook.sol";
import {ILMath} from "../src/ILMath.sol";

/// @notice Shared test base using per-LP routers.
///
/// The hook enforces `require(lp == sender)`, so the sender seen by the hook
/// (the address that called PoolManager) must match hookData.lp. A shared
/// router would make all LPs indistinguishable. Each LP gets its own router,
/// so sender == hookData.lp == that router address, and spoofed lp values revert.
/// Each router is also a separate PoolManager owner, so positions never commingle
/// even with salt 0 and identical ticks.
///
/// LP identity = address(lpRouter). Positions are keyed by hook.getPosition(poolId, address(lpRouter)).
/// Swaps use the shared swapRouter because afterSwap does not inspect lp.
abstract contract TrancheTestBase is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint256 internal constant WAD = 1e18;

    /// @dev Deploy a hook with given (buffer, alpha, hookFee) and initialize a pool at tick 0 (price 1.0).
    ///   The hook address namespace is salted by the params to avoid address collisions.
    function _deployHookAndPool(uint256 bufferWad, uint256 alphaWad, uint256 hookFeeWad)
        internal
        returns (TrancheHook hook, PoolKey memory key, PoolId poolId)
    {
        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        uint160 ns = uint160(uint256(keccak256(abi.encode(bufferWad, alphaWad, hookFeeWad))) & 0xffff);
        address hookAddress = address(flags ^ (ns << 144));
        bytes memory args = abi.encode(IPoolManager(address(manager)), bufferWad, alphaWad, hookFeeWad);
        deployCodeTo("TrancheHook.sol:TrancheHook", args, hookAddress);
        hook = TrancheHook(hookAddress);

        (key, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));
    }

    /// @dev Deploy a dedicated LP router and approve both currencies. The router address is the LP identity.
    function _newLp() internal returns (PoolModifyLiquidityTest lpRouter) {
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(lpRouter), type(uint256).max);
    }

    /// @dev Add liquidity via a dedicated LP router. hookData.lp must equal address(lpRouter).
    function _addLiq(
        PoolModifyLiquidityTest lpRouter,
        PoolKey memory key,
        TrancheHook.Tranche tranche,
        uint256 liq,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(liq), salt: 0}),
            abi.encode(address(lpRouter), tranche)
        );
    }

    /// @dev Remove liquidity via a dedicated LP router.
    function _removeLiq(
        PoolModifyLiquidityTest lpRouter,
        PoolKey memory key,
        TrancheHook.Tranche tranche,
        uint256 liq,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(liq), salt: 0}),
            abi.encode(address(lpRouter), tranche)
        );
    }

    /// @dev Execute a swap. Negative amountSpecified = exactInput.
    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 m = a < b ? a : b;
        return m < c ? m : c;
    }

    /// @dev Compute V_HODL_current using the same formula as the hook:
    ///   re-value entry amounts (amount0, amount1) at the current EMA price.
    ///   remove() does not update the EMA, so this is stable before and after removal.
    function _vHodlCurrent(TrancheHook hook, PoolId poolId, address lp) internal view returns (uint256) {
        TrancheHook.LpPosition memory pos = hook.getPosition(poolId, lp);
        uint160 emaP = hook.getPoolAccount(poolId).sqrtPriceEmaX96;
        return ILMath.depositValueInToken1(pos.amount0, pos.amount1, emaP);
    }
}
