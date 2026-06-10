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

/// @notice End-to-end demo with Monte Carlo-derived parameters injected verbatim.
///
/// This test proves that the on-chain mechanism accepts the (B, α) values
/// output by tranche_params.py and that Senior is protected by Junior capital.
/// It is a single-path illustration of mechanism correctness, not a reproduction
/// of the Monte Carlo distribution (that is the role of the Python analysis).
///
/// Parameters — tranche_params.py representative case ticks[-6000, +6000]:
///   σ=60%, T=30d, price range [0.5488, 1.8221], turnover=20x, buffer=90th pct, λ=0.30
///   B (buffer) = 0.0388  → BUFFER_WAD = 38775050248575256
///   α (alpha)  = 0.6262  → ALPHA_WAD  = 626226265377168256
///
/// HOOK_FEE_WAD is set high for demo visibility (to thicken the fund).
/// Production hook fees would be much lower (~0.3%).
contract TrancheHookDemoTest is TrancheTestBase {
    using StateLibrary for IPoolManager;

    uint256 constant BUFFER_WAD = 38775050248575256; // B = 3.88%
    uint256 constant ALPHA_WAD = 626226265377168256; // α = 0.626
    int24 constant TL = -6000; // price 0.5488
    int24 constant TU = 6000; // price 1.8221

    uint256 constant HOOK_FEE_WAD = 0.01e18;

    // Tuning knobs: increase N_SWAPS/SWAP_SIZE if IL is too low; decrease if PriceLimitAlreadyExceeded.
    uint256 constant N_SWAPS = 12;
    uint256 constant SWAP_SIZE = 0.3 ether;

    TrancheHook hook;
    PoolKey poolKey;
    PoolId poolId;

    PoolModifyLiquidityTest juniorRouter;
    PoolModifyLiquidityTest seniorRouter;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (hook, poolKey, poolId) = _deployHookAndPool(BUFFER_WAD, ALPHA_WAD, HOOK_FEE_WAD);

        juniorRouter = _newLp();
        seniorRouter = _newLp();

        _addLiq(juniorRouter, poolKey, TrancheHook.Tranche.JUNIOR, 10 ether, TL, TU);
        _addLiq(seniorRouter, poolKey, TrancheHook.Tranche.SENIOR, 10 ether, TL, TU);
    }

    /// @notice Verify that the MC-derived (B, α) are on-chain, and that Senior is protected.
    function test_demo_derivedParams_protectSenior() public {
        assertEq(hook.BUFFER_WAD(), BUFFER_WAD, "not using MC-derived buffer");
        assertEq(hook.ALPHA_WAD(), ALPHA_WAD, "not using MC-derived alpha");
        console2.log("== using Monte Carlo-derived params (ticks +/-6000) ==");
        console2.log("BUFFER_WAD", BUFFER_WAD);
        console2.log("ALPHA_WAD ", ALPHA_WAD);

        for (uint256 i = 0; i < N_SWAPS; i++) {
            _swap(poolKey, true, SWAP_SIZE);
        }

        (, uint256 ilLoss) = hook.quoteRealizedIl(poolId, address(seniorRouter));
        assertGt(ilLoss, 0, "no IL created -> raise N_SWAPS/SWAP_SIZE (watch PriceLimitAlreadyExceeded)");

        TrancheHook.PoolAccount memory bef = hook.getPoolAccount(poolId);
        assertGt(bef.juniorFundClaim, 0, "fund too thin -> raise HOOK_FEE_WAD or N_SWAPS");

        assertApproxEqRel(
            bef.juniorFundClaim, (bef.fundBalance * ALPHA_WAD) / WAD, 1e15, "alpha split != derived alpha"
        );

        uint256 principal = hook.getPosition(poolId, address(seniorRouter)).principal;
        uint256 vHodlCur = _vHodlCurrent(hook, poolId, address(seniorRouter));
        uint256 bufferAmount = ILMath.ilAmount(vHodlCur, BUFFER_WAD);
        _removeLiq(seniorRouter, poolKey, TrancheHook.Tranche.SENIOR, 10 ether, TL, TU);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);
        uint256 absorbed = bef.juniorFundClaim - aft.juniorFundClaim;
        uint256 residual = ilLoss > absorbed ? ilLoss - absorbed : 0;

        assertGt(absorbed, 0, "protection inactive");
        assertLt(residual, ilLoss, "senior not better than unprotected LP");
        uint256 expected = _min3(ilLoss, bufferAmount, bef.juniorFundClaim);
        assertEq(absorbed, expected, "absorbed != min(IL, buffer, fund)");

        console2.log("-- single-path illustration (not an expected-value claim) --");
        console2.log("principal (token1)      ", principal);
        console2.log("IL loss (plain LP bears)", ilLoss);
        console2.log("absorbed by junior fund ", absorbed);
        console2.log("residual borne by senior", residual);
        console2.log("protection ratio (bps)  ", ilLoss == 0 ? 0 : (absorbed * 10000) / ilLoss);
    }
}
