// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {ILMath} from "../src/ILMath.sol";

/// @notice ILMath の数値的健全性を fuzz で確認する。
///   ① ilFromSqrtPrices が極端な価格でも revert しない（overflow 懸念②の経験的反証）
///   ② IL 割合は [0, WAD] に収まる（HODL 比なので 100% を超えない）
///   ③ ilAmount は principal を超えない
contract ILMathFuzzTest is Test {
    uint256 constant WAD = 1e18;

    /// @notice ①+②: 任意の (entry, current) を有効な sqrtPrice 範囲で振り、
    ///   フルレンジ境界で ilFromSqrtPrices を呼んでも revert せず、結果が [0, WAD] に収まる。
    function testFuzz_ilFromSqrtPrices_noOverflow_bounded(uint160 entry, uint160 current) public pure {
        // 有効な sqrtPriceX96 範囲にクランプ（TickMath の下限/上限）
        entry = uint160(bound(entry, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        current = uint160(bound(current, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));

        // フルレンジ境界で呼ぶ（最も積が大きくなる = overflow が出るならここで出る）
        uint256 ilWad = ILMath.ilFromSqrtPrices(entry, current, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);

        // IL は HODL 比の損失割合なので 0〜100%(WAD) に収まるはず
        assertLe(ilWad, WAD, "IL ratio exceeds 100%");
    }

    /// @notice ③: ilAmount(principal, ilWad) は principal を超えない（ilWad <= WAD なら自明だが境界確認）。
    function testFuzz_ilAmount_neverExceedsPrincipal(uint256 principal, uint256 ilWad) public pure {
        principal = bound(principal, 0, 1e30); // 現実的な上限（1e12 ether 相当）
        ilWad = bound(ilWad, 0, WAD);

        uint256 loss = ILMath.ilAmount(principal, ilWad);
        assertLe(loss, principal, "loss exceeds principal");
    }

    /// @notice 補助: entry == current なら IL は 0（価格が動いていなければ損失なし）。
    function testFuzz_ilZeroWhenNoPriceMove(uint160 price) public pure {
        price = uint160(bound(price, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        uint256 ilWad = ILMath.ilFromSqrtPrices(price, price, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
        assertEq(ilWad, 0, "IL nonzero with no price move");
    }
}
