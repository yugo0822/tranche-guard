// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ILMath
/// @notice Impermanent loss を sqrtPriceX96 の entry/current 比から計算するライブラリ。
/// @dev すべての割合は WAD (1e18 = 100%) で表現する。
///
/// 数学的背景:
///   価格比 r = P_current / P_entry とすると、x*y=k の AMM では
///       value_LP / value_HODL = 2*sqrt(r) / (1 + r)
///   IL(r) = 1 - 2*sqrt(r)/(1+r)   (常に >= 0、価格が動くほど大きい)
///
///   v4 では価格は sqrtPriceX96 (= sqrt(P) * 2^96) で与えられる。よって
///       sqrt(r) = sqrt(P_cur/P_entry) = sqrtPrice_cur / sqrtPrice_entry
///   sqrt(r) が直接 sqrtPrice の比として得られるのが好都合。
library ILMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2^96

    /// @notice entry と current の sqrtPriceX96 から IL 割合 (WAD) を返す。
    /// @param sqrtPriceEntryX96 ポジション加入時の sqrtPriceX96
    /// @param sqrtPriceCurrentX96 現在の sqrtPriceX96
    /// @return ilWad IL 割合 (1e18 = 100%)。価格不変なら 0。
    function ilFromSqrtPrices(uint160 sqrtPriceEntryX96, uint160 sqrtPriceCurrentX96)
        internal
        pure
        returns (uint256 ilWad)
    {
        if (sqrtPriceEntryX96 == 0 || sqrtPriceCurrentX96 == 0) return 0;
        if (sqrtPriceEntryX96 == sqrtPriceCurrentX96) return 0;

        // sqrtR (WAD) = sqrtPrice_cur / sqrtPrice_entry  (= sqrt(r))
        // 比を WAD スケールで取る: (cur * WAD) / entry
        uint256 sqrtRWad = (uint256(sqrtPriceCurrentX96) * WAD) / uint256(sqrtPriceEntryX96);

        // r (WAD) = sqrtR^2
        // sqrtRWad は WAD スケールなので二乗すると WAD^2 → WAD に戻すため /WAD
        uint256 rWad = (sqrtRWad * sqrtRWad) / WAD;

        // 分子 numerator = 2 * sqrtR  (WAD)
        uint256 numerator = 2 * sqrtRWad;

        // 分母 denominator = 1 + r  (WAD)
        uint256 denominator = WAD + rWad;

        // ratio = 2*sqrtR / (1+r)  (WAD)
        uint256 ratioWad = (numerator * WAD) / denominator;

        // IL = 1 - ratio。数値誤差で ratio が WAD をわずかに超える場合は 0 にクランプ。
        if (ratioWad >= WAD) return 0;
        ilWad = WAD - ratioWad;
    }

    /// @notice IL 割合 (WAD) を資本額に適用して損失額 (トークン単位) を返す。
    /// @param principal ポジションの元本相当額
    /// @param ilWad IL 割合 (WAD)
    function ilAmount(uint256 principal, uint256 ilWad) internal pure returns (uint256) {
        return (principal * ilWad) / WAD;
    }
}
