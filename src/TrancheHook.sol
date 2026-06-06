// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {ILMath} from "./ILMath.sol";

/// @title TrancheHook
/// @notice Senior / Junior の2トランチで IL をウォーターフォール充当する Uniswap v4 hook。
///
/// ─────────────────────────────────────────────────────────────────────────
/// 経済モデル（確定）: fund 共有プールモデル
///   - 全スワップ手数料を hook が捕捉して fund(currency1) に貯める。
///   - α·F   → juniorFundClaim : Junior 集団の担保 兼 報酬
///     (1−α)·F → seniorFeeClaim  : Senior の手数料取り分
///   - Senior 保護(absorbed) は juniorFundClaim から引く → 肩代わりが Junior 全体に分散。
///   - 退出決済は常に「fund → LP への支払い」のみ。remove 時に user から take しない。
///
/// 成立条件（オフチェーンで連立して (B, α) を算出し注入）:
///   ΔL(B) < F のとき  α = ΔL/(2F) + 0.5
///
/// 簡略化（明示）:
///   - fund / IL は単一通貨 currency1 で会計（cross-currency 変換は TODO）。
///   - 1 LP = 1 position。
///   - auth は hookData 信頼。本番は PositionManager の owner 参照が必要。
///
/// ⚠️要検証の境界（forge build で一緒に潰す）:
///   [V2] afterSwapReturnDelta の符号と take() の組み合わせ（手数料捕捉）
///   [V3] afterRemoveLiquidityReturnDelta の符号と settle()（fund→LP 支払い）
///   [V4] BaseHook の各 _afterXxx オーバーライド署名（commit 依存）
/// ─────────────────────────────────────────────────────────────────────────
contract TrancheHook is BaseHook {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    /* ───────────────────────── 型定義 ───────────────────────── */

    enum Tranche {
        JUNIOR,
        SENIOR
    }

    struct LpPosition {
        address owner;
        Tranche tranche;
        uint256 principal;
        uint160 sqrtPriceEntryX96;
        int24 tickLower;
        int24 tickUpper;
        bool active;
    }

    struct PoolAccount {
        uint160 sqrtPriceEmaX96; // twap 化した参照価格（操作耐性）
        uint256 juniorPrincipalTotal;
        uint256 seniorPrincipalTotal;
        uint256 juniorFundClaim; // α·F の累積 − Senior 肩代わりで減る
        uint256 seniorFeeClaim; // (1−α)·F の累積
        uint256 fundBalance; // hook が実際に保有する currency1 トークン量
        bool initialized;
    }

    /* ───────────────────────── 状態変数 ───────────────────────── */

    uint256 public immutable BUFFER_WAD;
    uint256 public immutable ALPHA_WAD;

    /// @notice hook が swap から徴収する手数料率 (WAD)。F の原資。
    /// @dev pool の LP fee とは別に hook が上乗せ徴収する分。0 だと fund が貯まらない。
    uint256 public immutable HOOK_FEE_WAD;

    uint256 internal constant EMA_WINDOW = 8; // 大きいほど操作耐性↑・追従↓
    uint256 internal constant WAD = 1e18;

    mapping(PoolId => PoolAccount) public poolAccounts;
    mapping(PoolId => mapping(address => LpPosition)) public positions;

    /* ───────────────────────── イベント ───────────────────────── */

    event PositionOpened(
        PoolId indexed poolId, address indexed lp, Tranche tranche, uint256 principal, uint160 sqrtPriceEntryX96
    );
    event PositionClosed(
        PoolId indexed poolId,
        address indexed lp,
        Tranche tranche,
        uint256 realizedIlWad,
        uint256 lossBorne,
        uint256 payout
    );
    event WaterfallApplied(PoolId indexed poolId, uint256 totalIl, uint256 absorbedByJunior, uint256 residualToSenior);
    event FeesAccrued(PoolId indexed poolId, uint256 toJunior, uint256 toSenior);

    /* ───────────────────────── エラー ───────────────────────── */

    error NoPosition();
    error PositionInactive();
    error PositionAlreadyActive();
    error Unauthorized();

    /* ───────────────────────── 構築 ───────────────────────── */

    constructor(IPoolManager _manager, uint256 _bufferWad, uint256 _alphaWad, uint256 _hookFeeWad) BaseHook(_manager) {
        BUFFER_WAD = _bufferWad;
        ALPHA_WAD = _alphaWad;
        HOOK_FEE_WAD = _hookFeeWad;
    }

    /* ───────────────────────── 権限 ───────────────────────── */

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false, // 決済は afterRemoveLiquidity に集約
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true, // 手数料捕捉
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true // fund→LP 決済
        });
    }

    /* ───────────────────────── hookData ───────────────────────── */

    function encodeHookData(address lp, Tranche tranche, uint256 principal) external pure returns (bytes memory) {
        return abi.encode(lp, tranche, principal);
    }

    function _decodeHookData(bytes calldata hookData)
        internal
        pure
        returns (address lp, Tranche tranche, uint256 principal)
    {
        (lp, tranche, principal) = abi.decode(hookData, (address, Tranche, uint256));
    }

    /* ───────────────────────── afterAddLiquidity: 登録 ───────────────────────── */

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) {
            return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        (address lp, Tranche tranche,) = _decodeHookData(hookData);
        // TODO[auth]: lp は hookData 由来で詐称可能。本番は PositionManager の owner と突合する。

        PoolId poolId = key.toId();
        if (positions[poolId][lp].active) revert PositionAlreadyActive();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        uint256 amt0 = d0 < 0 ? uint256(uint128(-d0)) : 0;
        uint256 amt1 = d1 < 0 ? uint256(uint128(-d1)) : 0;
        uint256 principal = ILMath.depositValueInToken1(amt0, amt1, sqrtPriceX96);

        positions[poolId][lp] = LpPosition({
            owner: lp,
            tranche: tranche,
            principal: principal,
            sqrtPriceEntryX96: sqrtPriceX96,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            active: true
        });

        PoolAccount storage acct = poolAccounts[poolId];
        if (!acct.initialized) {
            acct.sqrtPriceEmaX96 = sqrtPriceX96;
            acct.initialized = true;
        }

        if (tranche == Tranche.JUNIOR) acct.juniorPrincipalTotal += principal;
        else acct.seniorPrincipalTotal += principal;

        emit PositionOpened(poolId, lp, tranche, principal, sqrtPriceX96);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /* ───────────────────────── afterSwap: 価格EMA + 手数料捕捉 ───────────────────────── */

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        PoolAccount storage acct = poolAccounts[poolId];

        // ── 価格 EMA 更新（操作耐性） ──
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        acct.sqrtPriceEmaX96 = _updateEma(acct.sqrtPriceEmaX96, sqrtPriceX96);

        // ── 手数料捕捉（fund の原資） ──
        // ⚠️[V2]: 「currency1 が unspecified の時だけ」捕捉する簡略版。
        //   exactInput/exactOutput と zeroForOne の組合せで unspecified が変わる点は要検証。
        int128 hookFee = 0;
        if (params.zeroForOne) {
            int128 out1 = delta.amount1();
            uint256 outAbs = out1 < 0 ? uint256(uint128(-out1)) : uint256(uint128(out1));
            uint256 fee = (outAbs * HOOK_FEE_WAD) / WAD;

            if (fee > 0) {
                // ⚠️[V2]: 正の hookDelta を返して取り分を主張し、take() で実トークン化。
                hookFee = int128(uint128(fee));
                key.currency1.take(poolManager, address(this), fee, false);

                uint256 toJunior = (fee * ALPHA_WAD) / WAD;
                uint256 toSenior = fee - toJunior;
                acct.juniorFundClaim += toJunior;
                acct.seniorFeeClaim += toSenior;
                acct.fundBalance += fee;
                emit FeesAccrued(poolId, toJunior, toSenior);
            }
        }
        // TODO[fee-skew]: currency0 側 swap の手数料も拾う（fund を2通貨化 or 変換）。

        return (BaseHook.afterSwap.selector, hookFee);
    }

    /* ───────────────────────── afterRemoveLiquidity: 充当 + 実決済 ───────────────────────── */

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) {
            return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        (address lp,,) = _decodeHookData(hookData);
        PoolId poolId = key.toId();
        LpPosition storage pos = positions[poolId][lp];

        if (pos.owner == address(0)) revert NoPosition();
        if (!pos.active) revert PositionInactive();

        PoolAccount storage acct = poolAccounts[poolId];

        uint256 ilWad = ILMath.ilFromSqrtPrices(
            pos.sqrtPriceEntryX96,
            acct.sqrtPriceEmaX96,
            TickMath.getSqrtPriceAtTick(pos.tickLower),
            TickMath.getSqrtPriceAtTick(pos.tickUpper)
        );
        uint256 ilLoss = ILMath.ilAmount(pos.principal, ilWad);

        uint256 lossBorne;
        uint256 fundPayout; // fund から LP に渡す currency1 額

        if (pos.tranche == Tranche.SENIOR) {
            // 保護: buffer まで Junior(fund) が肩代わり
            uint256 bufferAmount = ILMath.ilAmount(pos.principal, BUFFER_WAD);
            uint256 absorbed = ilLoss <= bufferAmount ? ilLoss : bufferAmount;
            if (absorbed > acct.juniorFundClaim) absorbed = acct.juniorFundClaim;
            acct.juniorFundClaim -= absorbed;

            uint256 residual = ilLoss > absorbed ? ilLoss - absorbed : 0;
            lossBorne = residual;

            uint256 feeShare =
                acct.seniorPrincipalTotal == 0 ? 0 : (acct.seniorFeeClaim * pos.principal) / acct.seniorPrincipalTotal;
            acct.seniorFeeClaim -= feeShare;

            fundPayout = absorbed + feeShare; // 保護分 + 手数料取り分
            acct.seniorPrincipalTotal -= _min(pos.principal, acct.seniorPrincipalTotal);

            emit WaterfallApplied(poolId, ilLoss, absorbed, residual);
        } else {
            // Junior: 自身の IL はプール退出で normal に実現（hook は補填しない）。
            // fund からは「残った取り分(= α手数料 − 肩代わり後)」をシェア按分で受け取る。
            lossBorne = ilLoss;
            uint256 feeShare =
                acct.juniorPrincipalTotal == 0 ? 0 : (acct.juniorFundClaim * pos.principal) / acct.juniorPrincipalTotal;
            acct.juniorFundClaim -= feeShare;

            fundPayout = feeShare;
            acct.juniorPrincipalTotal -= _min(pos.principal, acct.juniorPrincipalTotal);
        }

        // ── 実決済: fund → LP へ currency1 を支払う ──
        // ⚠️[V3]: 負の delta = hook が user に支払う、の符号で合っているか要検証。
        BalanceDelta hookDelta = BalanceDeltaLibrary.ZERO_DELTA;
        if (fundPayout > 0 && acct.fundBalance >= fundPayout) {
            acct.fundBalance -= fundPayout;
            key.currency1.settle(poolManager, address(this), fundPayout, false);
            hookDelta = toBalanceDelta(0, -int128(uint128(fundPayout)));
        }

        pos.active = false;
        emit PositionClosed(poolId, lp, pos.tranche, ilWad, lossBorne, fundPayout);

        return (BaseHook.afterRemoveLiquidity.selector, hookDelta);
    }

    /* ───────────────────────── 内部ヘルパ ───────────────────────── */

    /// @dev 整数 EMA: ema' = (ema*(W-1) + price) / W
    function _updateEma(uint160 ema, uint160 price) internal pure returns (uint160) {
        if (ema == 0) return price;
        uint256 next = (uint256(ema) * (EMA_WINDOW - 1) + uint256(price)) / EMA_WINDOW;
        return uint160(next);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /* ───────────────────────── view ───────────────────────── */

    function quoteRealizedIl(PoolId poolId, address lp) external view returns (uint256 ilWad, uint256 ilLoss) {
        LpPosition memory pos = positions[poolId][lp];
        if (pos.owner == address(0) || !pos.active) return (0, 0);
        ilWad = ILMath.ilFromSqrtPrices(
            pos.sqrtPriceEntryX96,
            poolAccounts[poolId].sqrtPriceEmaX96,
            TickMath.getSqrtPriceAtTick(pos.tickLower),
            TickMath.getSqrtPriceAtTick(pos.tickUpper)
        );
        ilLoss = ILMath.ilAmount(pos.principal, ilWad);
    }

    function getPosition(PoolId poolId, address lp) external view returns (LpPosition memory) {
        return positions[poolId][lp];
    }

    function getPoolAccount(PoolId poolId) external view returns (PoolAccount memory) {
        return poolAccounts[poolId];
    }
}
