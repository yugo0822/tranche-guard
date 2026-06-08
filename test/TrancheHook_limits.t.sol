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

/// @notice 保護の「限界ケース」テスト。保護が効きすぎないこと（buffer と fund で頭打ちすること）を示す。
///   ① IL > buffer  → absorbed が buffer で頭打ち、residual > 0（Senior が超過分を被る）
///   ② fund 不足     → absorbed が juniorFundClaim で頭打ち（保険基金が尽きたら守りきれない）
///   FIX[auth]: LP は専用ルーター経由（identity = ルーターアドレス）。
contract TrancheHookLimitsTest is TrancheTestBase {
    using StateLibrary for IPoolManager;

    uint256 constant BUFFER_WAD = 0.05e18; // 5%
    uint256 constant ALPHA_WAD = 0.70e18;

    // トランチ別 LP = 専用ルーター（setUp で生成、各 test で使い回す）
    PoolModifyLiquidityTest juniorRouter;
    PoolModifyLiquidityTest seniorRouter;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        juniorRouter = _newLp();
        seniorRouter = _newLp();
    }

    /* ───────────────────────── ① IL > buffer ───────────────────────── */

    /// @notice IL を buffer(5%) より大きくして、Senior が超過分(residual)を被ることを示す。
    ///   fund は潤沢にして「fund 不足ではなく buffer で頭打ち」を保証する。
    function test_limit_ilExceedsBuffer_seniorBearsResidual() public {
        // 手数料を厚め(20%)にして fund を潤沢に → 頭打ちは buffer 側で起きるようにする
        (TrancheHook hook, PoolKey memory key, PoolId poolId) = _deployHookAndPool(BUFFER_WAD, ALPHA_WAD, 0.20e18);

        // 狭めレンジ(±6000) + 大きいスワップで IL を 5% 超に押し上げる
        _addLiq(juniorRouter, key, TrancheHook.Tranche.JUNIOR, 10 ether, -6000, 6000);
        _addLiq(seniorRouter, key, TrancheHook.Tranche.SENIOR, 10 ether, -6000, 6000);

        // 価格を大きく動かす（IL を稼ぐ）
        for (uint256 i = 0; i < 20; i++) {
            _swap(key, true, 0.3 ether);
        }

        (, uint256 ilLoss) = hook.quoteRealizedIl(poolId, address(seniorRouter));
        uint256 principal = hook.getPosition(poolId, address(seniorRouter)).principal;
        uint256 bufferAmount = ILMath.ilAmount(principal, BUFFER_WAD);

        // 前提: IL が buffer を超えていること（超えていなければスワップ量/レンジ調整の合図）
        assertGt(ilLoss, bufferAmount, "IL <= buffer -> widen price move (more/bigger swaps, narrower range)");

        TrancheHook.PoolAccount memory bef = hook.getPoolAccount(poolId);
        // 前提: fund が buffer を超えている（fund 側で頭打ちさせない）
        assertGt(bef.juniorFundClaim, bufferAmount, "fund too thin -> this would cap at fund, not buffer");

        _removeLiq(seniorRouter, key, TrancheHook.Tranche.SENIOR, 10 ether, -6000, 6000);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);
        uint256 absorbed = bef.juniorFundClaim - aft.juniorFundClaim;
        uint256 residual = ilLoss - absorbed;

        // 核心の主張:
        // (a) absorbed は buffer で頭打ち（IL 全額ではない）
        assertEq(absorbed, bufferAmount, "absorbed should cap at buffer");
        // (b) Senior は超過分を被る（residual > 0）= 保護は無限ではない
        assertGt(residual, 0, "senior should bear the excess over buffer");
        // (c) ただし plain LP より損は小さい（residual < ilLoss）
        assertLt(residual, ilLoss, "senior still better than unprotected LP");

        console2.log("ilLoss      ", ilLoss);
        console2.log("bufferAmount", bufferAmount);
        console2.log("absorbed    ", absorbed);
        console2.log("residual    ", residual);
    }

    /* ───────────────────────── ② fund 不足 ───────────────────────── */

    /// @notice fund を薄くして、absorbed が juniorFundClaim で頭打ちになることを示す。
    ///   = 保険基金が尽きたら buffer 内でも守りきれない（feasibility 条件 ΔL < F が破れた状態）。
    function test_limit_fundInsufficient_absorbCapsAtFund() public {
        // 手数料を極小(0.01%)にして fund を薄く → 頭打ちは fund 側で起きる
        (TrancheHook hook, PoolKey memory key, PoolId poolId) = _deployHookAndPool(BUFFER_WAD, ALPHA_WAD, 0.0001e18);

        _addLiq(juniorRouter, key, TrancheHook.Tranche.JUNIOR, 10 ether, -887220, 887220);
        _addLiq(seniorRouter, key, TrancheHook.Tranche.SENIOR, 10 ether, -887220, 887220);

        // IL を出す（fund はほとんど貯まらない）
        for (uint256 i = 0; i < 10; i++) {
            _swap(key, true, 1 ether);
        }

        (, uint256 ilLoss) = hook.quoteRealizedIl(poolId, address(seniorRouter));
        assertGt(ilLoss, 0, "no IL created");

        TrancheHook.PoolAccount memory bef = hook.getPoolAccount(poolId);
        uint256 principal = hook.getPosition(poolId, address(seniorRouter)).principal;
        uint256 bufferAmount = ILMath.ilAmount(principal, BUFFER_WAD);

        // 前提: fund が「IL と buffer の両方」より小さい → fund 側で頭打ちになる状況
        assertLt(bef.juniorFundClaim, ilLoss, "fund not the binding constraint vs IL");
        assertLt(bef.juniorFundClaim, bufferAmount, "fund not the binding constraint vs buffer");

        _removeLiq(seniorRouter, key, TrancheHook.Tranche.SENIOR, 10 ether, -887220, 887220);

        TrancheHook.PoolAccount memory aft = hook.getPoolAccount(poolId);
        uint256 absorbed = bef.juniorFundClaim - aft.juniorFundClaim;

        // 核心の主張:
        // (a) absorbed は fund 残高で頭打ち（buffer でも IL でもなく fund が制約）
        assertEq(absorbed, bef.juniorFundClaim, "absorbed should cap at fund balance");
        // (b) Junior 資金が枯渇（肩代わりに使い切った）
        assertEq(aft.juniorFundClaim, 0, "junior fund should be drained");
        // (c) Senior は大きな residual を被る（保護しきれていない）
        uint256 residual = ilLoss - absorbed;
        assertGt(residual, 0, "senior bears large residual when fund is dry");

        console2.log("ilLoss           ", ilLoss);
        console2.log("juniorFundClaim  ", bef.juniorFundClaim);
        console2.log("absorbed (capped)", absorbed);
        console2.log("residual         ", residual);
    }
}
