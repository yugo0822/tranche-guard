// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
// ⚠️[API] per-LP ルーターの本体。root の test/ にある。remapping は他のテストと同じ "v4-core/test/..."。
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
// ⚠️[API] approve 用の最小 ERC20 IF。solmate の MockERC20 を import せずに済むよう v4-core 内のものを使う。
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

import {TrancheHook} from "../src/TrancheHook.sol";

/// @notice per-LP ルーター方式の共有テスト基盤。
///
///   ─ なぜ per-LP ルーターか（FIX[auth] の前提）─
///   hook が `require(lp == sender)` を課したので、hook が見る sender（= PoolManager を叩いた
///   アドレス）と hookData.lp が一致せねばならない。共有 modifyLiquidityRouter だと sender が
///   全 LP 共通になり区別できないため、LP ごとに専用ルーターをデプロイする。
///   これにより sender == hookData.lp == そのルーターアドレス となり、別人の lp 指定（なりすまし）
///   が revert する。さらに各ルーターは PoolManager 上で別 owner になるので、salt 0・同 tick でも
///   ポジションが commingle しない（共有ルーター時の副作用も同時に解消）。
///
///   ─ LP identity ─
///   LP の識別子 = 専用ルーターのアドレス address(lpRouter)。
///   ポジション参照も hook.getPosition(poolId, address(lpRouter)) で引く。
///   スワップは認証不要（hook._afterSwap は lp を見ない）なので共有 swapRouter のまま。
abstract contract TrancheTestBase is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint256 internal constant WAD = 1e18;

    /// @dev hook を (buffer, alpha, hookFee) 指定でデプロイし、tick0(price 1.0)でプール初期化して返す。
    ///   fee/params ごとにアドレス名前空間を散らして衝突回避（フラグ部は不変）。
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
        // ⚠️[API] deployCodeTo の引数順（"path:Contract", ctorArgs, targetAddr）。
        deployCodeTo("TrancheHook.sol:TrancheHook", args, hookAddress);
        hook = TrancheHook(hookAddress);

        // ⚠️[API] initPool 署名（fee 3000 = 0.3%。hook 手数料はこれとは別枠）。
        (key, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));
    }

    /// @dev LP 専用ルーターをデプロイし、両 currency を approve。返り値(=router address)が LP identity。
    ///   approve は本テスト契約(address(this))のトークンを lpRouter に許可する（router が transferFrom する）。
    function _newLp() internal returns (PoolModifyLiquidityTest lpRouter) {
        // ⚠️[API] PoolModifyLiquidityTest のコンストラクタ引数（IPoolManager）。
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(lpRouter), type(uint256).max);
    }

    /// @dev 指定ルーター(=LP)経由で流動性追加。hookData.lp は必ず address(lpRouter)=sender に一致させる。
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
            abi.encode(address(lpRouter), tranche, liq)
        );
    }

    /// @dev 指定ルーター(=LP)経由で流動性除去。
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
            abi.encode(address(lpRouter), tranche, liq)
        );
    }

    /// @dev スワップ（共有 swapRouter で OK。hook は swap で lp を見ない）。負 amount = exactInput。
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
}
