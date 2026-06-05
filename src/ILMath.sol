// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @title ILMath
/// @notice 集中流動性(concentrated liquidity)に対応した IL 計算ライブラリ。
/// @dev Uniswap v2 の full range 公式は集中流動性では IL を大幅に過小評価する。
///      本ライブラリは tickLower/tickUpper のレンジを考慮し、レンジアウトも正しく扱う。
///      すべての割合は WAD (1e18 = 100%)。
///
/// 数学的背景:
///   流動性 L、レンジ [P_L, P_U]、現在価格 P でのトークン量 (token0=x, token1=y):
///     P <= P_L          : x = L(1/√P_L − 1/√P_U),  y = 0
///     P_L <= P <= P_U   : x = L(1/√P   − 1/√P_U),  y = L(√P − √P_L)
///     P >= P_U          : x = 0,                    y = L(√P_U − √P_L)
///   token1 建て価値: V = x·P + y    (P = token1/token0)
///
///   HODL 価値:  entry 時のトークン量 (x0,y0) を current 価格で評価 = x0·P_cur + y0
///   IL = 1 − V_lp(P_cur) / V_hodl(P_cur)
///
///   sqrtPriceX96 (= √P · 2^96) を直接使う。L は IL の比の中で相殺されるため L = 2^96 と置く。
///   ※ 重要: トークン量はレンジ端でクランプ(数量固定)するが、価値評価は必ず現在価格で行う。
library ILMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2^96

    /// @notice token1 建てのポジション価値を返す（L = Q96 固定、相対値）。
    /// @dev トークン量はレンジ内にクランプした価格で決める（レンジアウト時の数量固定）。
    ///      ただし token0 の価値評価は必ず現在価格 sqrtPEval で行う（数量固定 != 価値固定）。
    /// @param sqrtPClamp トークン量決定用の価格（内部でレンジ内にクランプ）
    /// @param sqrtPEval  価値評価に使う現在価格の sqrtPriceX96
    /// @param sqrtPL     レンジ下限の sqrtPriceX96
    /// @param sqrtPU     レンジ上限の sqrtPriceX96
    /// @return value     token1 建て価値（スケール: Q96）
    function _positionValue(uint256 sqrtPClamp, uint256 sqrtPEval, uint256 sqrtPL, uint256 sqrtPU)
        private
        pure
        returns (uint256 value)
    {
        // トークン量を決める価格 sp はレンジ内にクランプ（レンジ外なら端で数量固定）
        uint256 sp = sqrtPClamp;
        if (sp < sqrtPL) sp = sqrtPL;
        if (sp > sqrtPU) sp = sqrtPU;

        // token1量 y (Q96スケール) = (sp − sqrtPL)
        uint256 y = sp - sqrtPL;

        // token0量 x (Q96スケール) = Q96^2·(sqrtPU − sp) / (sp·sqrtPU)
        uint256 xNum = FullMath.mulDiv(Q96, sqrtPU - sp, sqrtPU);
        uint256 x = FullMath.mulDiv(xNum, Q96, sp);

        // token0 の価値は「現在価格」で評価する: x · P_eval, P_eval = sqrtPEval^2/Q96^2
        // ここでは sp(数量決定価格) == sqrtPEval(評価価格) なので、x が大きいとき sqrtPEval は小さく、
        // 逆も成り立つため xP は spU 程度に有界で overflow しない（数量価格==評価価格が効く）。
        uint256 xP = FullMath.mulDiv(x, sqrtPEval, Q96);
        xP = FullMath.mulDiv(xP, sqrtPEval, Q96);

        value = xP + y;
    }

    /// @notice 集中流動性ポジションの実現 IL 割合 (WAD) を返す。
    /// @param sqrtPriceEntryX96 加入時価格
    /// @param sqrtPriceCurrentX96 現在価格
    /// @param sqrtPriceLowerX96 レンジ下限
    /// @param sqrtPriceUpperX96 レンジ上限
    function ilFromSqrtPrices(
        uint160 sqrtPriceEntryX96,
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96
    ) internal pure returns (uint256 ilWad) {
        if (sqrtPriceEntryX96 == 0 || sqrtPriceCurrentX96 == 0) return 0;
        if (sqrtPriceEntryX96 == sqrtPriceCurrentX96) return 0;
        if (sqrtPriceLowerX96 >= sqrtPriceUpperX96) return 0;

        uint256 spE = uint256(sqrtPriceEntryX96);
        uint256 spC = uint256(sqrtPriceCurrentX96);
        uint256 spL = uint256(sqrtPriceLowerX96);
        uint256 spU = uint256(sqrtPriceUpperX96);

        uint256 pCur = FullMath.mulDiv(spC, spC, Q96); // P_cur = spC^2/Q96 (Q96スケール)

        // entry 時のトークン量（entry価格 spE をクランプして決める。数量のみ）
        uint256 spEc = spE;
        if (spEc < spL) spEc = spL;
        if (spEc > spU) spEc = spU;
        uint256 y0 = spEc - spL; // token1量(Q96)
        uint256 xNum0 = FullMath.mulDiv(Q96, spU - spEc, spU);
        uint256 x0 = FullMath.mulDiv(xNum0, Q96, spEc); // token0量(Q96)

        // ── HODL 価値 = x0·P_cur + y0（entry数量を現在価格で評価）──
        //   ⚠️ 極端な乖離（entry が極低価格→token0 を大量保有 かつ current が極高価格）では
        //      x0·pCur/Q96 が真の値として 2^256 を超え、FullMath.mulDiv が revert する。
        //      この領域では HODL がレンジ制約の LP を天文学的に上回るため IL は 100%(WAD) に飽和する。
        //      FullMath と同じ 512bit 高位ワード判定で overflow を厳密検知し、WAD を返す。
        //      （逆 side: entry高→current低 は pCur→0 で x0 leg が消えるため overflow しない）
        uint256 hodl0;
        {
            uint256 prod0; // x0*pCur の低位 256bit
            uint256 prod1; // x0*pCur の高位 256bit
            assembly {
                let mm := mulmod(x0, pCur, not(0))
                prod0 := mul(x0, pCur)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            // result = (prod1:prod0)/Q96 が uint256 に収まる条件は prod1 < Q96。
            //   収まらない = HODL の token0 leg が 2^256 超 = LP は相対的にほぼ無価値 → IL=WAD。
            if (prod1 >= Q96) return WAD;
            hodl0 = FullMath.mulDiv(x0, pCur, Q96);
        }
        // hodl0 + y0 の加算 overflow も同様に IL=WAD（極端領域でのみ起こり、そこでは IL≈WAD）。
        if (hodl0 > type(uint256).max - y0) return WAD;
        uint256 vHodl = hodl0 + y0;

        // LP 価値（数量は current でクランプ、評価は current 価格）
        uint256 vLp = _positionValue(spC, spC, spL, spU);

        if (vHodl == 0) return 0;
        if (vLp >= vHodl) return 0;

        ilWad = FullMath.mulDiv(vHodl - vLp, WAD, vHodl);
    }

    /// @notice IL 割合 (WAD) を元本に適用して損失額を返す。
    function ilAmount(uint256 principal, uint256 ilWad) internal pure returns (uint256) {
        return FullMath.mulDiv(principal, ilWad, WAD);
    }
}
