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

/// @notice END-TO-END デモ: tranche_params.py が導出した「実際のパラメータ」をそのまま注入し、
///   その値で機構が動く（Senior が Junior 資本に守られる）ことをオンチェーンで示す。
///
///   ─ これは「機構＋パイプライン統合の例示」であって「Monte Carlo 分布の再現」ではない ─
///   * Monte Carlo (analysis/tranche_params.py) = なぜこの (B, α) を選ぶかの統計的正当化
///   * 本テスト                                 = その (B, α) が実 v4 hook を駆動する証明（1パス）
///   1パスの結果から期待値や loss-prob を主張してはいけない（それは MC の役割。保護の"量"は MC チャートが担う）。
///   本テストの一番の価値は assertEq(hook.BUFFER_WAD(), 導出値) 等＝「Python の出力が文字通りオンチェーンに乗ってる」縫い目。
///
///   ─ 使用パラメータ（tranche_params.py 代表ケース ±6000 の出力をそのまま）─
///     σ=60%, T=30d, ticks[-6000,+6000] (price[0.5488,1.8221]), turnover=20x, buffer=90%ile, λ=0.30
///       B (buffer) = 0.0388 -> BUFFER_WAD = 38775050248575256
///       α (alpha)  = 0.6262 -> ALPHA_WAD  = 626226265377168256
///
///   ─ レンジ整合 ─
///     プールを tick 0 (price 1.0) で初期化し、LP を ticks[-6000,+6000] にデプロイ = MC のレンジと 1:1。
///     ±6000 は ±3000 より広く swap volume を飲めるので、駆動が楽（limits① で実証済みのレンジ）。
///
///   ─ HOOK_FEE について（正直な注記）─
///     本デモの HOOK_FEE はデモ可視化用（fund を厚くして保護を見せる）。本番想定の上乗せ率はずっと小さい(~0.3%)。
///     MC の F(=rate×turnover) とは定義が別で、本テストは F を再現していない（機構の例示のみ）。
contract TrancheHookDemoTest is TrancheTestBase {
    using StateLibrary for IPoolManager;

    /* ── tranche_params.py 代表ケース ±6000 の導出値（そのまま注入）── */
    uint256 constant BUFFER_WAD = 38775050248575256; // B = 3.88%
    uint256 constant ALPHA_WAD = 626226265377168256; // α = 0.626 (Junior 62.6% / Senior 37.4%)
    int24 constant TL = -6000; // price 0.5488
    int24 constant TU = 6000; // price 1.8221

    // デモ可視化用 HOOK_FEE（本番は ~0.3%）。fund を厚くして保護を可視化するため高め。
    uint256 constant HOOK_FEE_WAD = 0.01e18;

    // ── スワップ駆動ノブ（±6000 は広いので強めに打てる）──
    //   ・IL が出ない("no IL created") → 回数 or サイズを上げる
    //   ・fund 不足("fund too thin")   → HOOK_FEE か回数を上げる
    //   ・PriceLimitAlreadyExceeded    → 回数 or サイズを下げる
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

        // MC が想定したレンジ ticks[-6000,+6000] にデプロイ（= MC の IL 分布のレンジと 1:1）
        _addLiq(juniorRouter, poolKey, TrancheHook.Tranche.JUNIOR, 10 ether, TL, TU);
        _addLiq(seniorRouter, poolKey, TrancheHook.Tranche.SENIOR, 10 ether, TL, TU);
    }

    /// @notice 導出した (B, α) を注入したプールで、Senior が Junior 資本に守られることを示す。
    function test_demo_derivedParams_protectSenior() public {
        // ── 0) このプールが「MC の導出値」で動いていることを明示（パイプラインの両端を縫う）──
        assertEq(hook.BUFFER_WAD(), BUFFER_WAD, "not using MC-derived buffer");
        assertEq(hook.ALPHA_WAD(), ALPHA_WAD, "not using MC-derived alpha");
        console2.log("== using Monte Carlo-derived params (ticks +/-6000) ==");
        console2.log("BUFFER_WAD", BUFFER_WAD);
        console2.log("ALPHA_WAD ", ALPHA_WAD);

        // ── 1) 価格を動かして IL を起こしつつ fund を貯める ──
        for (uint256 i = 0; i < N_SWAPS; i++) {
            _swap(poolKey, true, SWAP_SIZE);
        }

        // ── 2) 前提チェック（外れたらノブ調整の合図）──
        (, uint256 ilLoss) = hook.quoteRealizedIl(poolId, address(seniorRouter));
        assertGt(ilLoss, 0, "no IL created -> raise N_SWAPS/SWAP_SIZE (watch PriceLimitAlreadyExceeded)");

        TrancheHook.PoolAccount memory bef = hook.getPoolAccount(poolId);
        assertGt(bef.juniorFundClaim, 0, "fund too thin -> raise HOOK_FEE_WAD or N_SWAPS");

        // ── 3) α 配分が「導出した α」で効いていることを確認 ──
        assertApproxEqRel(
            bef.juniorFundClaim, (bef.fundBalance * ALPHA_WAD) / WAD, 1e15, "alpha split != derived alpha"
        );

        // ── 4) Senior 退出 → 保護経路が走る ──
        uint256 principal = hook.getPosition(poolId, address(seniorRouter)).principal;
        uint256 bufferAmount = ILMath.ilAmount(principal, BUFFER_WAD); // hook と同一式
        _removeLiq(seniorRouter, poolKey, TrancheHook.Tranche.SENIOR, 10 ether, TL, TU);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);
        uint256 absorbed = bef.juniorFundClaim - aft.juniorFundClaim;
        uint256 residual = ilLoss > absorbed ? ilLoss - absorbed : 0;

        // ── 5) 主張（どれも 1パスで常に成り立つ「機構」の性質。期待値の主張ではない）──
        assertGt(absorbed, 0, "protection inactive");
        assertLt(residual, ilLoss, "senior not better than unprotected LP");
        uint256 expected = _min3(ilLoss, bufferAmount, bef.juniorFundClaim);
        assertEq(absorbed, expected, "absorbed != min(IL, buffer, fund)");

        // ── 6) デモ用ログ（plain LP との対比。あくまで1パスの例示）──
        console2.log("-- single-path illustration (not an expected-value claim) --");
        console2.log("principal (token1)      ", principal);
        console2.log("IL loss (plain LP bears)", ilLoss);
        console2.log("absorbed by junior fund ", absorbed);
        console2.log("residual borne by senior", residual);
        console2.log("protection ratio (bps)  ", ilLoss == 0 ? 0 : (absorbed * 10000) / ilLoss);
    }
}
