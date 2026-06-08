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
/// IL 損失の基準（FIX[#3]）:
///   ilWad は「current HODL に対する損失比率」なので、損失額は entry 価値ではなく
///   current HODL 価値 V_HODL_cur で評価する: ilLoss = ilWad × V_HODL_cur。
///   V_HODL_cur = entry 数量(amount0, amount1) を current(EMA) 価格で再評価。
///   これで MC の ratio 比較(ilWad vs B)と完全整合し、注入した (B,α) がオンチェーン挙動に対応する。
///
/// 簡略化（明示）:
///   - fund / IL は単一通貨 currency1 で会計（cross-currency 変換は TODO）。
///   - 1 LP = 1 position、かつ remove は「登録レンジ・全量」のみ（FIX[#1] で強制）。
///   - auth は sender == lp（FIX[auth]）。本番の custodial ルーター(共有)対応は PositionManager の ownerOf 委譲。
///
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
        uint128 amount0; // FIX[#3]: entry 数量（V_HODL_current 評価用）
        uint128 amount1; // FIX[#3]: entry 数量
        uint128 liquidity; // FIX[#1]: 登録時の L（フルクローズ検証用）
        uint256 principal; // entry token1 価値（fee 按分の重み）
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
    error RangeMismatch();
    error PartialCloseNotAllowed();
    error InvalidParam();
    error FundInvariantBroken();

    /* ───────────────────────── 構築 ───────────────────────── */

    constructor(IPoolManager _manager, uint256 _bufferWad, uint256 _alphaWad, uint256 _hookFeeWad) BaseHook(_manager) {
        // ALPHA_WAD > WAD → toSenior = fee - toJunior が underflow して swap 全断。
        // HOOK_FEE_WAD > WAD → fee > outAbs となり PoolManager のバランスチェックで swap 全断。
        // BUFFER_WAD > WAD → bufferAmount > vHodlCur で経済的に不正（IL 全量を常に補填）。
        if (_alphaWad > WAD || _hookFeeWad > WAD || _bufferWad > WAD) revert InvalidParam();
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

    function encodeHookData(address lp, Tranche tranche) external pure returns (bytes memory) {
        return abi.encode(lp, tranche);
    }

    function _decodeHookData(bytes calldata hookData)
        internal
        pure
        returns (address lp, Tranche tranche)
    {
        (lp, tranche) = abi.decode(hookData, (address, Tranche));
    }

    /* ───────────────────────── afterAddLiquidity: 登録 ───────────────────────── */

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) {
            return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        (address lp, Tranche tranche) = _decodeHookData(hookData);
        if (lp != sender) revert Unauthorized();
        // FIX[auth]: lp == sender を強制。custodial ルーター(共有)対応は PositionManager の ownerOf 委譲（roadmap）。

        PoolId poolId = key.toId();
        if (positions[poolId][lp].active) revert PositionAlreadyActive();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // FIX[②]: principal は PoolManager 由来の delta（実預入量）を entry 価格で token1 評価。
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        uint256 amt0 = d0 < 0 ? uint256(uint128(-d0)) : 0;
        uint256 amt1 = d1 < 0 ? uint256(uint128(-d1)) : 0;
        uint256 principal = ILMath.depositValueInToken1(amt0, amt1, sqrtPriceX96);

        positions[poolId][lp] = LpPosition({
            owner: lp,
            tranche: tranche,
            amount0: uint128(amt0), // FIX[#3]: V_HODL_cur 評価のため entry 数量を保存
            amount1: uint128(amt1), // FIX[#3]
            liquidity: uint128(uint256(params.liquidityDelta)), // FIX[#1]: フルクローズ検証用
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
        int128 hookFee = 0;
        if (params.zeroForOne) {
            int128 out1 = delta.amount1();
            uint256 outAbs = out1 < 0 ? uint256(uint128(-out1)) : uint256(uint128(out1));
            uint256 fee = (outAbs * HOOK_FEE_WAD) / WAD;

            if (fee > 0) {
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
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) {
            return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        (address lp,) = _decodeHookData(hookData);
        if (lp != sender) revert Unauthorized();

        PoolId poolId = key.toId();
        LpPosition storage pos = positions[poolId][lp];

        if (pos.owner == address(0)) revert NoPosition();
        if (!pos.active) revert PositionInactive();

        // FIX[#1]: remove は登録時と同じレンジ・全量でなければならない。
        //   部分 remove / 別レンジ remove で「フル principal の保護を払い出して active=false」される
        //   過剰決済 → fund ドレインを封じる。MVP の「1 LP = 1 position・フルクローズ」前提を強制。
        if (params.tickLower != pos.tickLower || params.tickUpper != pos.tickUpper) revert RangeMismatch();
        if (uint256(-params.liquidityDelta) != pos.liquidity) revert PartialCloseNotAllowed();

        PoolAccount storage acct = poolAccounts[poolId];

        uint256 ilWad = ILMath.ilFromSqrtPrices(
            pos.sqrtPriceEntryX96,
            acct.sqrtPriceEmaX96,
            TickMath.getSqrtPriceAtTick(pos.tickLower),
            TickMath.getSqrtPriceAtTick(pos.tickUpper)
        );
        // FIX[#3]: ilWad は current HODL 比率なので、entry 価値(principal)ではなく current HODL 価値で評価。
        //   ilWad と同じ価格(EMA)で entry 数量を再評価 → 真の絶対 IL。MC の ratio 比較とも整合。
        uint256 vHodlCur = ILMath.depositValueInToken1(pos.amount0, pos.amount1, acct.sqrtPriceEmaX96);
        uint256 ilLoss = ILMath.ilAmount(vHodlCur, ilWad);

        uint256 lossBorne;
        uint256 fundPayout; // fund から LP に渡す currency1 額

        if (pos.tranche == Tranche.SENIOR) {
            // 保護: buffer まで Junior(fund) が肩代わり（buffer も current HODL の B%）
            uint256 bufferAmount = ILMath.ilAmount(vHodlCur, BUFFER_WAD); // FIX[#3]
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

        pos.active = false;

        // ── 実決済: fund → LP へ currency1 を支払う（Interaction 最後）──
        // 不変条件 juniorFundClaim + seniorFeeClaim == fundBalance が保たれる限り
        // fundBalance >= fundPayout は常に真。偽は別バグによる不変条件崩壊 → fail-loud。
        if (fundPayout > acct.fundBalance) revert FundInvariantBroken();
        BalanceDelta hookDelta = BalanceDeltaLibrary.ZERO_DELTA;
        if (fundPayout > 0) {
            acct.fundBalance -= fundPayout;
            key.currency1.settle(poolManager, address(this), fundPayout, false); // interaction
            hookDelta = toBalanceDelta(0, -int128(uint128(fundPayout)));
        }

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
        uint160 emaP = poolAccounts[poolId].sqrtPriceEmaX96;
        ilWad = ILMath.ilFromSqrtPrices(
            pos.sqrtPriceEntryX96,
            emaP,
            TickMath.getSqrtPriceAtTick(pos.tickLower),
            TickMath.getSqrtPriceAtTick(pos.tickUpper)
        );
        // FIX[#3]: current HODL 価値でスケール（entry の principal ではなく）。
        uint256 vHodlCur = ILMath.depositValueInToken1(pos.amount0, pos.amount1, emaP);
        ilLoss = ILMath.ilAmount(vHodlCur, ilWad);
    }

    function getPosition(PoolId poolId, address lp) external view returns (LpPosition memory) {
        return positions[poolId][lp];
    }

    function getPoolAccount(PoolId poolId) external view returns (PoolAccount memory) {
        return poolAccounts[poolId];
    }
}
