// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {TrancheHook} from "../src/TrancheHook.sol";
import {ILMath} from "../src/ILMath.sol";
import {TrancheTestBase} from "./TrancheTestBase.sol";

/// @notice Edge-case tests for protection caps.
///   (1) IL > buffer  → absorbed caps at buffer; Senior bears the residual.
///   (2) Fund too thin → absorbed caps at juniorFundClaim; fund is drained.
contract TrancheHookLimitsTest is TrancheTestBase {
    using StateLibrary for IPoolManager;

    uint256 constant BUFFER_WAD = 0.05e18; // 5%
    uint256 constant ALPHA_WAD = 0.7e18;

    PoolModifyLiquidityTest juniorRouter;
    PoolModifyLiquidityTest seniorRouter;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        juniorRouter = _newLp();
        seniorRouter = _newLp();
    }

    /* ------------------------------------------------------------------ */
    /*  (1) IL > buffer                                                     */
    /* ------------------------------------------------------------------ */

    /// @notice IL exceeds the 5% buffer: absorbed caps at buffer and Senior bears the residual.
    ///   Uses a high hook fee to keep the fund ample so the buffer — not the fund — is the binding cap.
    function test_limit_ilExceedsBuffer_seniorBearsResidual() public {
        (TrancheHook hook, PoolKey memory key, PoolId poolId) = _deployHookAndPool(BUFFER_WAD, ALPHA_WAD, 0.2e18);

        _addLiq(juniorRouter, key, TrancheHook.Tranche.JUNIOR, 10 ether, -6000, 6000);
        _addLiq(seniorRouter, key, TrancheHook.Tranche.SENIOR, 10 ether, -6000, 6000);

        // 30 × 0.2 ether pushes price near the lower edge of [-6000, 6000] (spot IL ~12% > 5% buffer).
        // Total ~6 ether stays below the range capacity (~6.98 ether) to avoid PriceLimitAlreadyExceeded.
        for (uint256 i = 0; i < 30; i++) {
            _swap(key, true, 0.2 ether);
        }

        (, uint256 ilLoss) = hook.quoteRealizedIl(poolId, address(seniorRouter));
        uint256 bufferAmount = ILMath.ilAmount(_vHodlCurrent(hook, poolId, address(seniorRouter)), BUFFER_WAD);

        assertGt(ilLoss, bufferAmount, "IL <= buffer -> widen price move (more/bigger swaps, narrower range)");

        TrancheHook.PoolAccount memory bef = hook.getPoolAccount(poolId);
        assertGt(bef.juniorFundClaim, bufferAmount, "fund too thin -> this would cap at fund, not buffer");

        _removeLiq(seniorRouter, key, TrancheHook.Tranche.SENIOR, 10 ether, -6000, 6000);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);
        uint256 absorbed = bef.juniorFundClaim - aft.juniorFundClaim;
        uint256 residual = ilLoss - absorbed;

        assertEq(absorbed, bufferAmount, "absorbed should cap at buffer");
        assertGt(residual, 0, "senior should bear the excess over buffer");
        assertLt(residual, ilLoss, "senior still better than unprotected LP");

        console2.log("ilLoss      ", ilLoss);
        console2.log("bufferAmount", bufferAmount);
        console2.log("absorbed    ", absorbed);
        console2.log("residual    ", residual);
    }

    /* ------------------------------------------------------------------ */
    /*  (2) Fund insufficient                                               */
    /* ------------------------------------------------------------------ */

    /// @notice Fund is thinner than both IL and the buffer: absorbed caps at juniorFundClaim.
    function test_limit_fundInsufficient_absorbCapsAtFund() public {
        (TrancheHook hook, PoolKey memory key, PoolId poolId) = _deployHookAndPool(BUFFER_WAD, ALPHA_WAD, 0.0001e18);

        _addLiq(juniorRouter, key, TrancheHook.Tranche.JUNIOR, 10 ether, -887220, 887220);
        _addLiq(seniorRouter, key, TrancheHook.Tranche.SENIOR, 10 ether, -887220, 887220);

        for (uint256 i = 0; i < 10; i++) {
            _swap(key, true, 1 ether);
        }

        (, uint256 ilLoss) = hook.quoteRealizedIl(poolId, address(seniorRouter));
        assertGt(ilLoss, 0, "no IL created");

        TrancheHook.PoolAccount memory bef = hook.getPoolAccount(poolId);
        uint256 bufferAmount = ILMath.ilAmount(_vHodlCurrent(hook, poolId, address(seniorRouter)), BUFFER_WAD);

        assertLt(bef.juniorFundClaim, ilLoss, "fund not the binding constraint vs IL");
        assertLt(bef.juniorFundClaim, bufferAmount, "fund not the binding constraint vs buffer");

        _removeLiq(seniorRouter, key, TrancheHook.Tranche.SENIOR, 10 ether, -887220, 887220);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);
        uint256 absorbed = bef.juniorFundClaim - aft.juniorFundClaim;

        assertEq(absorbed, bef.juniorFundClaim, "absorbed should cap at fund balance");
        assertEq(aft.juniorFundClaim, 0, "junior fund should be drained");
        uint256 residual = ilLoss - absorbed;
        assertGt(residual, 0, "senior bears large residual when fund is dry");

        console2.log("ilLoss           ", ilLoss);
        console2.log("juniorFundClaim  ", bef.juniorFundClaim);
        console2.log("absorbed (capped)", absorbed);
        console2.log("residual         ", residual);
    }
}
