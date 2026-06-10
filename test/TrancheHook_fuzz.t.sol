// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {ILMath} from "../src/ILMath.sol";

/// @notice Fuzz tests for ILMath numerical correctness.
///   (1) ilFromSqrtPrices never reverts for any valid price pair (no overflow).
///   (2) IL ratio is always in [0, WAD].
///   (3) ilAmount never exceeds principal.
contract ILMathFuzzTest is Test {
    uint256 constant WAD = 1e18;

    /// @notice Any (entry, current) in the valid sqrtPrice range must not revert, and result in [0, WAD].
    function testFuzz_ilFromSqrtPrices_noOverflow_bounded(uint160 entry, uint160 current) public pure {
        entry = uint160(bound(entry, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        current = uint160(bound(current, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));

        uint256 ilWad = ILMath.ilFromSqrtPrices(entry, current, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);

        assertLe(ilWad, WAD, "IL ratio exceeds 100%");
    }

    /// @notice ilAmount(principal, ilWad) must not exceed principal when ilWad <= WAD.
    function testFuzz_ilAmount_neverExceedsPrincipal(uint256 principal, uint256 ilWad) public pure {
        principal = bound(principal, 0, 1e30);
        ilWad = bound(ilWad, 0, WAD);

        uint256 loss = ILMath.ilAmount(principal, ilWad);
        assertLe(loss, principal, "loss exceeds principal");
    }

    /// @notice IL must be zero when entry price equals current price.
    function testFuzz_ilZeroWhenNoPriceMove(uint160 price) public pure {
        price = uint160(bound(price, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        uint256 ilWad = ILMath.ilFromSqrtPrices(price, price, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
        assertEq(ilWad, 0, "IL nonzero with no price move");
    }
}
