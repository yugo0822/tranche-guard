// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

// ⚠️ これらは v4-core の src/test/ 配下にある（root の test/ にある CurrencySettler とは別位置）。
//   src/ を足す v4-core/ remapping 経由で掴む。
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {TrancheHook} from "../src/TrancheHook.sol";
import {ILMath} from "../src/ILMath.sol"; // bufferAmount を hook と同じ式で出すため

/// @notice [V2] 手数料捕捉 と [V3] fund→LP 決済の符号・機構を検証するテスト。
///   ⚠️マークの API は pin commit で署名が違う可能性あり。失敗したら貼ってくれれば直す。
contract TrancheHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    TrancheHook hook;
    PoolKey poolKey;
    PoolId poolId;

    // パラメータ（テストで効果が見えるよう手数料率は高め）
    uint256 constant BUFFER_WAD = 0.05e18; // 5%
    uint256 constant ALPHA_WAD = 0.70e18; // Junior 70% / Senior 30%
    uint256 constant HOOK_FEE_WAD = 0.10e18; // 出力の 10%（テストで fund を厚く貯め保護を見せるため。本番はもっと小さい）

    // トランチ別 LP（hookData の識別子。実トークンの流れとは別）
    address juniorLp = makeAddr("juniorLp");
    address seniorLp = makeAddr("seniorLp");

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        deployMintAndApprove2Currencies();

        // Deploy TrancheHook
        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags ^ (uint160(0x4444) << 144)); // 名前空間化して衝突回避
        bytes memory args = abi.encode(IPoolManager(address(manager)), BUFFER_WAD, ALPHA_WAD, HOOK_FEE_WAD);
        deployCodeTo("TrancheHook.sol:TrancheHook", args, hookAddress); // ⚠️ deployCodeTo の引数順
        hook = TrancheHook(hookAddress);

        // ③ プール初期化（fee 3000 = 0.3%。hook 手数料はこれとは別枠）
        (poolKey, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0)); // ⚠️ initPool 署名

        // ④ Junior と Senior が流動性を追加（hookData でトランチ申告）
        _addTrancheLiquidity(juniorLp, TrancheHook.Tranche.JUNIOR, 10 ether);
        _addTrancheLiquidity(seniorLp, TrancheHook.Tranche.SENIOR, 10 ether);
    }

    /* ───────────────────────── [V2] 手数料捕捉 ───────────────────────── */

    function test_V2_feeCapturedOnSwap() public {
        TrancheHook.PoolAccount memory before = hook.getPoolAccount(poolId);
        assertEq(before.fundBalance, 0, "fund should start empty");

        uint256 hookBal0 = currency1.balanceOf(address(hook));

        // zeroForOne スワップ（currency0 入れて currency1 を受け取る → unspecified = currency1）
        _swap(true, 1 ether);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);

        // 1) fund が増えた = take() で hook が currency1 を実際に引き取れた
        assertGt(aft.fundBalance, 0, "[V2] fund did not grow -> take/return-delta sign wrong");

        // 2) hook の現物 currency1 残高が fund と一致（claims=false で実トークン化できている）
        assertEq(
            currency1.balanceOf(address(hook)) - hookBal0, aft.fundBalance, "[V2] held tokens != fund ledger"
        );

        // 3) α 配分が正しい（juniorFundClaim : seniorFeeClaim = α : 1-α）
        assertApproxEqRel(
            aft.juniorFundClaim, (aft.fundBalance * ALPHA_WAD) / 1e18, 1e15, "[V2] alpha split wrong (junior)"
        );
        assertEq(aft.juniorFundClaim + aft.seniorFeeClaim, aft.fundBalance, "[V2] ledger != fund");

        console2.log("fundBalance", aft.fundBalance);
        console2.log("juniorFundClaim", aft.juniorFundClaim);
        console2.log("seniorFeeClaim", aft.seniorFeeClaim);
    }

    /* ───────────────────────── tick 範囲の保存 ───────────────────────── */

    function test_position_storesTickRange() public view{
        TrancheHook.LpPosition memory pos = hook.getPosition(poolId, juniorLp);
        assertEq(pos.tickLower, int24(-887220), "tickLower not stored");
        assertEq(pos.tickUpper, int24(887220), "tickUpper not stored");
        assertTrue(pos.active, "position should be active");
    }

    /* ───────────────────────── [V3] fund→LP 決済 ───────────────────────── */

    function test_V3_settlementPaysFromFund() public {
        // 先に fund を貯める
        _swap(true, 2 ether);
        TrancheHook.PoolAccount memory beforeAcct = hook.getPoolAccount(poolId);
        assertGt(beforeAcct.fundBalance, 0, "need fund before settle");

        uint256 hookBalBefore = currency1.balanceOf(address(hook));
        uint256 recipientBefore = currency1.balanceOf(address(this)); // ルータ経由で最終的に test 契約へ

        // Senior が退出（hookData でトランチ識別）。fund から feeShare(+保護分) を受け取れるはず。
        _removeTrancheLiquidity(seniorLp, TrancheHook.Tranche.SENIOR, 10 ether);

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

    /* ───────────────────────── 保護（デモの本丸） ───────────────────────── */

    /// @notice 価格を動かして IL を起こし、Senior が Junior 資本に守られることを示す。
    ///   absorbed > 0（肩代わり発生）かつ Senior の被損 < 全 IL（plain LP より損が小さい）を主張する。
    function test_protection_seniorIsShielded() public {
        // 1. zeroForOne を連発 → 価格を一方向に動かして IL 発生 + fund 蓄積（同じスワップで両方進む）
        for (uint256 i = 0; i < 10; i++) {
            _swap(true, 1 ether);
        }

        // 2. 退出前に IL が出ているか確認（出なければスワップ量 or EMA_WINDOW を調整する合図）
        (, uint256 ilLoss) = hook.quoteRealizedIl(poolId, seniorLp);
        assertGt(ilLoss, 0, "no IL created -> swap more / lower EMA_WINDOW");

        TrancheHook.PoolAccount memory before = hook.getPoolAccount(poolId);
        assertGt(before.juniorFundClaim, 0, "fund empty -> raise HOOK_FEE_WAD or swap more");

        // 3. Senior 退出（absorbed 経路がここで初めて走る）
        _removeTrancheLiquidity(seniorLp, TrancheHook.Tranche.SENIOR, 10 ether);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);

        // 4a) Junior が肩代わりした = juniorFundClaim が absorbed 分だけ減った（③ の整合）
        //     Senior 退出で juniorFundClaim を動かすのは absorbed のみ。
        uint256 absorbed = before.juniorFundClaim - aft.juniorFundClaim;
        assertGt(absorbed, 0, "junior absorbed nothing -> protection inactive");

        // 4b) Senior が実際に被った損失 < 全 IL（= plain LP は全 IL を被るので、それより小さい）
        uint256 residual = ilLoss > absorbed ? ilLoss - absorbed : 0;
        assertLt(residual, ilLoss, "senior bore full IL -> not protected");

        // 4c) absorbed は過不足なく min(IL, buffer, fund)（過剰肩代わりも取りこぼしもない）
        //     bufferAmount は hook と同一の ILMath.ilAmount で算出して厳密一致を確認。
        uint256 principal = hook.getPosition(poolId, seniorLp).principal;
        uint256 bufferAmount = ILMath.ilAmount(principal, BUFFER_WAD);
        uint256 expectedAbsorbed = _min3(ilLoss, bufferAmount, before.juniorFundClaim);
        assertEq(absorbed, expectedAbsorbed, "absorbed != min(IL, buffer, fund)");

        console2.log("ilLoss (full, plain LP)", ilLoss);
        console2.log("absorbed by junior     ", absorbed);
        console2.log("residual to senior     ", residual);
    }

    /* ───────────────────────── ヘルパ ───────────────────────── */

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 m = a < b ? a : b;
        return m < c ? m : c;
    }

    function _addTrancheLiquidity(address lp, TrancheHook.Tranche tranche, uint256 principal) internal {
        bytes memory hookData = abi.encode(lp, tranche, principal);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(principal), salt: 0}),
            hookData
        ); // ⚠️ modifyLiquidity 署名 / ModifyLiquidityParams のフィールド
    }

    function _removeTrancheLiquidity(address lp, TrancheHook.Tranche tranche, uint256 principal) internal {
        bytes memory hookData = abi.encode(lp, tranche, principal);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: -int256(principal), salt: 0}),
            hookData
        );
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn), // 負 = exactInput
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            "" // swap には hookData 不要
        ); // ⚠️ swap 署名 / TestSettings のフィールド
    }
}
