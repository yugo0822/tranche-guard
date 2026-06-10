// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {TrancheHook} from "../src/TrancheHook.sol";
import {ILMath} from "../src/ILMath.sol";
import {TrancheTestBase} from "./TrancheTestBase.sol";

/// @notice Tests for fee capture and fund→LP settlement mechanics.
contract TrancheHookTest is TrancheTestBase {
    using StateLibrary for IPoolManager;

    uint256 constant BUFFER_WAD = 0.05e18; // 5%
    uint256 constant ALPHA_WAD = 0.7e18; // Junior 70% / Senior 30%
    uint256 constant HOOK_FEE_WAD = 0.01e18; // 1% of output

    int24 constant TL = -887220; // full range
    int24 constant TU = 887220;

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

    /* ------------------------------------------------------------------ */
    /*  Fee capture                                                         */
    /* ------------------------------------------------------------------ */

    function test_V2_feeCapturedOnSwap() public {
        TrancheHook.PoolAccount memory bef = hook.getPoolAccount(poolId);
        assertEq(bef.fundBalance, 0, "fund should start empty");

        uint256 hookBal0 = currency1.balanceOf(address(hook));

        _swap(poolKey, true, 1 ether);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);

        assertGt(aft.fundBalance, 0, "[V2] fund did not grow -> take/return-delta sign wrong");
        assertEq(currency1.balanceOf(address(hook)) - hookBal0, aft.fundBalance, "[V2] held tokens != fund ledger");
        assertApproxEqRel(
            aft.juniorFundClaim, (aft.fundBalance * ALPHA_WAD) / WAD, 1e15, "[V2] alpha split wrong (junior)"
        );
        assertEq(aft.juniorFundClaim + aft.seniorFeeClaim, aft.fundBalance, "[V2] ledger != fund");

        console2.log("fundBalance", aft.fundBalance);
        console2.log("juniorFundClaim", aft.juniorFundClaim);
        console2.log("seniorFeeClaim", aft.seniorFeeClaim);
    }

    /* ------------------------------------------------------------------ */
    /*  Position storage                                                    */
    /* ------------------------------------------------------------------ */

    function test_position_storesTickRange() public view {
        TrancheHook.LpPosition memory pos = hook.getPosition(poolId, address(juniorRouter));
        assertEq(pos.tickLower, TL, "tickLower not stored");
        assertEq(pos.tickUpper, TU, "tickUpper not stored");
        assertTrue(pos.active, "position should be active");
    }

    /* ------------------------------------------------------------------ */
    /*  Fund→LP settlement                                                  */
    /* ------------------------------------------------------------------ */

    function test_V3_settlementPaysFromFund() public {
        _swap(poolKey, true, 2 ether);
        TrancheHook.PoolAccount memory beforeAcct = hook.getPoolAccount(poolId);
        assertGt(beforeAcct.fundBalance, 0, "need fund before settle");

        uint256 hookBalBefore = currency1.balanceOf(address(hook));
        uint256 recipientBefore = currency1.balanceOf(address(this));

        _removeLiq(seniorRouter, poolKey, TrancheHook.Tranche.SENIOR, 10 ether, TL, TU);

        TrancheHook.PoolAccount memory afterAcct = hook.getPoolAccount(poolId);

        assertLt(afterAcct.fundBalance, beforeAcct.fundBalance, "[V3] fund did not decrease -> not paid out");
        uint256 paid = beforeAcct.fundBalance - afterAcct.fundBalance;
        assertEq(hookBalBefore - currency1.balanceOf(address(hook)), paid, "[V3] settled token != ledger delta");
        assertGt(currency1.balanceOf(address(this)), recipientBefore, "[V3] recipient got no extra currency1");

        console2.log("paid from fund", paid);
    }

    /* ------------------------------------------------------------------ */
    /*  Senior protection                                                   */
    /* ------------------------------------------------------------------ */

    function test_protection_seniorIsShielded() public {
        for (uint256 i = 0; i < 10; i++) {
            _swap(poolKey, true, 1 ether);
        }

        (, uint256 ilLoss) = hook.quoteRealizedIl(poolId, address(seniorRouter));
        assertGt(ilLoss, 0, "no IL created -> swap more / lower EMA_WINDOW");

        TrancheHook.PoolAccount memory bef = hook.getPoolAccount(poolId);
        assertGt(bef.juniorFundClaim, 0, "fund empty -> raise HOOK_FEE_WAD or swap more");

        _removeLiq(seniorRouter, poolKey, TrancheHook.Tranche.SENIOR, 10 ether, TL, TU);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);

        uint256 absorbed = bef.juniorFundClaim - aft.juniorFundClaim;
        assertGt(absorbed, 0, "junior absorbed nothing -> protection inactive");

        uint256 residual = ilLoss > absorbed ? ilLoss - absorbed : 0;
        assertLt(residual, ilLoss, "senior bore full IL -> not protected");

        uint256 vHodlCur = _vHodlCurrent(hook, poolId, address(seniorRouter));
        uint256 bufferAmount = ILMath.ilAmount(vHodlCur, BUFFER_WAD);
        uint256 expectedAbsorbed = _min3(ilLoss, bufferAmount, bef.juniorFundClaim);
        assertEq(absorbed, expectedAbsorbed, "absorbed != min(IL, buffer, fund)");

        console2.log("ilLoss (full, plain LP)", ilLoss);
        console2.log("absorbed by junior     ", absorbed);
        console2.log("residual to senior     ", residual);
    }

    /* ------------------------------------------------------------------ */
    /*  Auth: hookData spoofing rejected                                    */
    /* ------------------------------------------------------------------ */

    /// @notice An attacker router claiming hookData.lp = victim must revert.
    ///   victim has no active position, so the only revert path is Unauthorized (sender != lp).
    function test_auth_cannotSpoofOtherLp() public {
        PoolModifyLiquidityTest attacker = _newLp();
        address victim = makeAddr("victim");

        // v4 wraps hook reverts in WrappedError; bare expectRevert catches it regardless.
        vm.expectRevert();
        attacker.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: int256(1 ether), salt: 0}),
            abi.encode(victim, TrancheHook.Tranche.JUNIOR)
        );
    }
}
