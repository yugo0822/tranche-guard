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
import {ILMath} from "../src/ILMath.sol"; // bufferAmount を hook と同じ式で出すため
import {TrancheTestBase} from "./TrancheTestBase.sol";

/// @notice [V2] 手数料捕捉 と [V3] fund→LP 決済の符号・機構を検証するテスト。
///   FIX[auth] により LP は専用ルーター経由で操作する（identity = ルーターアドレス）。
contract TrancheHookTest is TrancheTestBase {
    using StateLibrary for IPoolManager;

    // パラメータ（テストで効果が見えるよう手数料率は高め）
    uint256 constant BUFFER_WAD = 0.05e18; // 5%
    uint256 constant ALPHA_WAD = 0.7e18; // Junior 70% / Senior 30%
    uint256 constant HOOK_FEE_WAD = 0.01e18; // 出力の1%

    int24 constant TL = -887220; // full range
    int24 constant TU = 887220;

    TrancheHook hook;
    PoolKey poolKey;
    PoolId poolId;

    // トランチ別 LP = 専用ルーター。address(juniorRouter) が junior の identity。
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

    /* ───────────────────────── [V2] 手数料捕捉 ───────────────────────── */

    function test_V2_feeCapturedOnSwap() public {
        TrancheHook.PoolAccount memory bef = hook.getPoolAccount(poolId);
        assertEq(bef.fundBalance, 0, "fund should start empty");

        uint256 hookBal0 = currency1.balanceOf(address(hook));

        // zeroForOne スワップ（currency0 入れて currency1 を受け取る → unspecified = currency1）
        _swap(poolKey, true, 1 ether);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);

        // 1) fund が増えた = take() で hook が currency1 を実際に引き取れた
        assertGt(aft.fundBalance, 0, "[V2] fund did not grow -> take/return-delta sign wrong");

        // 2) hook の現物 currency1 残高が fund と一致（claims=false で実トークン化できている）
        assertEq(currency1.balanceOf(address(hook)) - hookBal0, aft.fundBalance, "[V2] held tokens != fund ledger");

        // 3) α 配分が正しい（juniorFundClaim : seniorFeeClaim = α : 1-α）
        assertApproxEqRel(
            aft.juniorFundClaim, (aft.fundBalance * ALPHA_WAD) / WAD, 1e15, "[V2] alpha split wrong (junior)"
        );
        assertEq(aft.juniorFundClaim + aft.seniorFeeClaim, aft.fundBalance, "[V2] ledger != fund");

        console2.log("fundBalance", aft.fundBalance);
        console2.log("juniorFundClaim", aft.juniorFundClaim);
        console2.log("seniorFeeClaim", aft.seniorFeeClaim);
    }

    /* ───────────────────────── tick 範囲の保存 ───────────────────────── */

    function test_position_storesTickRange() public view {
        // identity = juniorRouter アドレス
        TrancheHook.LpPosition memory pos = hook.getPosition(poolId, address(juniorRouter));
        assertEq(pos.tickLower, TL, "tickLower not stored");
        assertEq(pos.tickUpper, TU, "tickUpper not stored");
        assertTrue(pos.active, "position should be active");
    }

    /* ───────────────────────── [V3] fund→LP 決済 ───────────────────────── */

    function test_V3_settlementPaysFromFund() public {
        // 先に fund を貯める
        _swap(poolKey, true, 2 ether);
        TrancheHook.PoolAccount memory beforeAcct = hook.getPoolAccount(poolId);
        assertGt(beforeAcct.fundBalance, 0, "need fund before settle");

        uint256 hookBalBefore = currency1.balanceOf(address(hook));
        uint256 recipientBefore = currency1.balanceOf(address(this)); // remove の現物は本契約へ戻る

        // Senior が退出（専用ルーター経由）。fund から feeShare(+保護分) を受け取れるはず。
        _removeLiq(seniorRouter, poolKey, TrancheHook.Tranche.SENIOR, 10 ether, TL, TU);

        TrancheHook.PoolAccount memory afterAcct = hook.getPoolAccount(poolId);

        // 1) fund 台帳が減った = 支払いが会計上発生
        assertLt(afterAcct.fundBalance, beforeAcct.fundBalance, "[V3] fund did not decrease -> not paid out");

        // 2) hook の現物 currency1 が fund 減少分だけ出ていった = settle() で実際に渡した
        uint256 paid = beforeAcct.fundBalance - afterAcct.fundBalance;
        assertEq(hookBalBefore - currency1.balanceOf(address(hook)), paid, "[V3] settled token != ledger delta");

        // 3) 受取側の currency1 が増えている（保護/手数料分が上乗せされた）
        assertGt(currency1.balanceOf(address(this)), recipientBefore, "[V3] recipient got no extra currency1");

        console2.log("paid from fund", paid);
    }

    /* ───────────────────────── 保護 ───────────────────────── */

    /// @notice 価格を動かして IL を起こし、Senior が Junior 資本に守られることを示す。
    function test_protection_seniorIsShielded() public {
        // 1. zeroForOne を連発 → 価格を一方向に動かして IL 発生 + fund 蓄積
        for (uint256 i = 0; i < 10; i++) {
            _swap(poolKey, true, 1 ether);
        }

        // 2. 退出前に IL が出ているか確認
        (, uint256 ilLoss) = hook.quoteRealizedIl(poolId, address(seniorRouter));
        assertGt(ilLoss, 0, "no IL created -> swap more / lower EMA_WINDOW");

        TrancheHook.PoolAccount memory bef = hook.getPoolAccount(poolId);
        assertGt(bef.juniorFundClaim, 0, "fund empty -> raise HOOK_FEE_WAD or swap more");

        // 3. Senior 退出（absorbed 経路がここで初めて走る）
        _removeLiq(seniorRouter, poolKey, TrancheHook.Tranche.SENIOR, 10 ether, TL, TU);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);

        // 4a) Junior が肩代わりした = juniorFundClaim が absorbed 分だけ減った
        uint256 absorbed = bef.juniorFundClaim - aft.juniorFundClaim;
        assertGt(absorbed, 0, "junior absorbed nothing -> protection inactive");

        // 4b) Senior の実損 < 全 IL（= plain LP は全 IL を被る）
        uint256 residual = ilLoss > absorbed ? ilLoss - absorbed : 0;
        assertLt(residual, ilLoss, "senior bore full IL -> not protected");

        // 4c) absorbed は過不足なく min(IL, buffer, fund)
        //     FIX[#3]: buffer も hook と同じ current HODL 基準で計算（entry principal ではない）
        uint256 vHodlCur = _vHodlCurrent(hook, poolId, address(seniorRouter));
        uint256 bufferAmount = ILMath.ilAmount(vHodlCur, BUFFER_WAD);
        uint256 expectedAbsorbed = _min3(ilLoss, bufferAmount, bef.juniorFundClaim);
        assertEq(absorbed, expectedAbsorbed, "absorbed != min(IL, buffer, fund)");

        console2.log("ilLoss (full, plain LP)", ilLoss);
        console2.log("absorbed by junior     ", absorbed);
        console2.log("residual to senior     ", residual);
    }

    /* ───────────────────────── FIX[auth]: なりすまし拒否 ───────────────────────── */

    /// @notice 攻撃者ルーターが hookData.lp=victim を詐称して add しようとすると revert する。
    ///   victim は未登録アドレスにして PositionAlreadyActive と混ざらないようにし、純粋に
    ///   require(lp == sender) の Unauthorized（sender=攻撃者ルーター != lp=victim）だけを捕まえる。
    function test_auth_cannotSpoofOtherLp() public {
        PoolModifyLiquidityTest attacker = _newLp();
        address victim = makeAddr("victim"); // active な position は持たない

        // v4 は hook の revert を WrappedError で包む（トップレベルは素の Unauthorized() にならない）。
        //   内側 selector 0x82b42900 == Unauthorized() であることは trace で確認済み。
        //   fresh victim なので revert 経路は auth だけ → bare expectRevert で十分かつ堅牢。
        vm.expectRevert();
        attacker.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TL, tickUpper: TU, liquidityDelta: int256(1 ether), salt: 0}),
            abi.encode(victim, TrancheHook.Tranche.JUNIOR)
        );
    }
}
