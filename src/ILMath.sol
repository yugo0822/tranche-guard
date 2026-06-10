// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @title ILMath
/// @notice Impermanent loss library for concentrated liquidity positions.
/// @dev The Uniswap v2 full-range formula severely underestimates IL for concentrated positions.
///      This library accounts for the tick range and handles out-of-range correctly.
///      All ratios are in WAD (1e18 = 100%).
///
/// Math background (L = liquidity, range [P_L, P_U], current price P):
///   P <= P_L  : x = L(1/√P_L − 1/√P_U),  y = 0
///   P_L<P<P_U : x = L(1/√P   − 1/√P_U),  y = L(√P − √P_L)
///   P >= P_U  : x = 0,                    y = L(√P_U − √P_L)
///   token1-denominated value: V = x·P + y
///
///   HODL value: entry amounts (x0, y0) re-valued at current price = x0·P_cur + y0
///   IL = 1 − V_lp(P_cur) / V_hodl(P_cur)
///
///   sqrtPriceX96 (= √P · 2^96) is used directly.
///   L cancels in the IL ratio, so L = 2^96 (= Q96) is substituted throughout.
///   Token quantities are clamped to range endpoints, but value is always evaluated at the current price.
library ILMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2^96

    /// @notice Returns the token1-denominated position value (L = Q96, relative scale).
    /// @dev Token quantities are determined by clamping sqrtPClamp into [sqrtPL, sqrtPU].
    ///      token0 value is always evaluated at sqrtPEval (the caller's current price),
    ///      not at the clamped price — clamping fixes quantities, not values.
    /// @param sqrtPClamp Price used to determine token quantities (clamped internally).
    /// @param sqrtPEval  Current sqrtPriceX96 used to value token0.
    /// @param sqrtPL     Range lower bound sqrtPriceX96.
    /// @param sqrtPU     Range upper bound sqrtPriceX96.
    /// @return value     token1-denominated value (Q96 scale).
    function _positionValue(uint256 sqrtPClamp, uint256 sqrtPEval, uint256 sqrtPL, uint256 sqrtPU)
        private
        pure
        returns (uint256 value)
    {
        uint256 sp = sqrtPClamp;
        if (sp < sqrtPL) sp = sqrtPL;
        if (sp > sqrtPU) sp = sqrtPU;

        uint256 y = sp - sqrtPL;
        uint256 xNum = FullMath.mulDiv(Q96, sqrtPU - sp, sqrtPU);
        uint256 x = FullMath.mulDiv(xNum, Q96, sp);

        // x · P_eval = x · sqrtPEval² / Q96².
        // When this function is called with sp == sqrtPEval (LP value path), large x implies
        // small sqrtPEval, so xP stays bounded near sqrtPU — no overflow.
        uint256 xP = FullMath.mulDiv(x, sqrtPEval, Q96);
        xP = FullMath.mulDiv(xP, sqrtPEval, Q96);

        value = xP + y;
    }

    /// @notice Returns the realized IL ratio (WAD) for a concentrated liquidity position.
    /// @param sqrtPriceEntryX96   sqrtPriceX96 at position entry.
    /// @param sqrtPriceCurrentX96 Current sqrtPriceX96 (typically the EMA price).
    /// @param sqrtPriceLowerX96   Range lower bound sqrtPriceX96.
    /// @param sqrtPriceUpperX96   Range upper bound sqrtPriceX96.
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

        uint256 pCur = FullMath.mulDiv(spC, spC, Q96); // P_cur in Q96 scale

        uint256 spEc = spE;
        if (spEc < spL) spEc = spL;
        if (spEc > spU) spEc = spU;
        uint256 y0 = spEc - spL;
        uint256 xNum0 = FullMath.mulDiv(Q96, spU - spEc, spU);
        uint256 x0 = FullMath.mulDiv(xNum0, Q96, spEc);

        // HODL value = x0·P_cur + y0 (entry amounts valued at current price).
        // When entry price is very low (large x0) and current price is very high (large pCur),
        // x0·pCur can exceed 2^256, which would cause FullMath.mulDiv to revert.
        // In that regime HODL dominates LP by an astronomical factor → IL saturates to 100%.
        // Detect overflow using the same 512-bit high-word technique as FullMath.
        uint256 hodl0;
        {
            uint256 prod0;
            uint256 prod1; // high 256 bits of x0 * pCur
            assembly {
                let mm := mulmod(x0, pCur, not(0))
                prod0 := mul(x0, pCur)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            // (prod1:prod0) / Q96 fits in uint256 iff prod1 < Q96.
            // If it doesn't fit, the token0 HODL leg alone exceeds 2^256 → IL = WAD.
            if (prod1 >= Q96) return WAD;
            hodl0 = FullMath.mulDiv(x0, pCur, Q96);
        }
        // Addition overflow is also possible in the same extreme regime → IL = WAD.
        if (hodl0 > type(uint256).max - y0) return WAD;
        uint256 vHodl = hodl0 + y0;

        uint256 vLp = _positionValue(spC, spC, spL, spU);

        if (vHodl == 0) return 0;
        if (vLp >= vHodl) return 0;

        ilWad = FullMath.mulDiv(vHodl - vLp, WAD, vHodl);
    }

    /// @notice Applies an IL ratio (WAD) to a principal to get the absolute loss.
    function ilAmount(uint256 principal, uint256 ilWad) internal pure returns (uint256) {
        return FullMath.mulDiv(principal, ilWad, WAD);
    }

    /// @notice Values deposited token amounts in token1 at the given entry price.
    /// @dev Derives principal from the actual PoolManager delta rather than self-reported hookData,
    ///      preventing principal inflation attacks on fee pro-rata and protection payouts.
    ///      token1-denomination aligns with the currency1-denominated fund and waterfall.
    ///      value = amount1 + amount0 · P,  where P = sqrtPriceX96² / Q96².
    function depositValueInToken1(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256)
    {
        uint256 p = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q96);
        return amount1 + FullMath.mulDiv(amount0, p, Q96);
    }
}
