// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {ILMath} from "./ILMath.sol";

/// @title TrancheHook
/// @notice LP を Senior / Junior の2トランチに分け、IL 損失をウォーターフォール充当する Uniswap v4 hook。
///
/// 設計（MVP）:
///   - LP は加入時に hookData で tranche と principal を申告する。
///   - afterSwap で最新の sqrtPriceX96 を記録（価格追跡）。
///   - beforeRemoveLiquidity で実現 IL を計算し、ウォーターフォールを適用:
///       Senior 退出時: IL のうち buffer まで Junior 資本が肩代わり、超過分のみ Senior 負担。
///       Junior 退出時: 自身の IL を全額負担。
///   - buffer (B) と手数料配分 (alpha) はオフチェーン (Python) で IL 分布から事前算出し、
///     コンストラクタで immutable 注入する。
///
/// MVP で意図的に省くもの（拡張で対応）:
///   - 加入時プレミアムの ReturnDelta 天引き（ここでは会計記録のみ）
///   - 実トークン決済（payout 額の計算と資本会計に集中）
///   - 1 LP 複数ポジション（1 pool = 1 position / LP に簡略化）
contract TrancheHook is BaseHook {
    using StateLibrary for IPoolManager;

    /* ───────────────────────── 型定義 ───────────────────────── */

    enum Tranche {
        JUNIOR, // IL を先に吸収。手数料取り分 alpha
        SENIOR // buffer まで保護。手数料取り分 (1 - alpha)
    }

    struct LpPosition {
        address owner;
        Tranche tranche;
        uint256 principal; // 元本相当額（IL を当てる基準）
        uint160 sqrtPriceEntryX96; // 加入時価格
        bool active;
    }

    struct PoolAccount {
        uint160 sqrtPriceLastX96; // afterSwap で更新する最新価格
        uint256 juniorCapital; // Junior トランチの現在資本（肩代わりで減る）
        uint256 seniorCapital; // Senior トランチの現在資本
        uint256 juniorPrincipalTotal; // Junior 元本合計（手数料配分の分母）
        uint256 seniorPrincipalTotal; // Senior 元本合計
    }

    /* ───────────────────────── 状態変数 ───────────────────────── */

    /// @notice Senior バッファ厚 (WAD)。IL のうちこの割合までを Junior が肩代わりする。
    /// @dev オフチェーンで IL 分布の p%ile から算出した値を注入。
    uint256 public immutable BUFFER_WAD;

    /// @notice Junior の手数料取り分 (WAD, 0.5e18〜1e18)。Senior は (1 - alpha)。
    uint256 public immutable ALPHA_WAD;

    mapping(PoolId => PoolAccount) public poolAccounts;
    mapping(PoolId => mapping(address => LpPosition)) public positions;

    /* ───────────────────────── イベント ───────────────────────── */

    event PositionOpened(
        PoolId indexed poolId, address indexed lp, Tranche tranche, uint256 principal, uint160 sqrtPriceEntryX96
    );
    event PositionClosed(
        PoolId indexed poolId,
        address indexed lp,
        Tranche tranche,
        uint256 realizedIlWad,
        uint256 lossBorne,
        uint256 payout
    );
    event WaterfallApplied(PoolId indexed poolId, uint256 totalIl, uint256 absorbedByJunior, uint256 residualToSenior);

    /* ───────────────────────── エラー ───────────────────────── */

    error NoPosition();
    error PositionInactive();

    /* ───────────────────────── 構築 ───────────────────────── */

    constructor(IPoolManager _manager, uint256 _bufferWad, uint256 _alphaWad) BaseHook(_manager) {
        BUFFER_WAD = _bufferWad;
        ALPHA_WAD = _alphaWad;
    }

    /* ───────────────────────── 権限 ───────────────────────── */

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: true, // 退出時に IL 計算 + ウォーターフォール
            afterAddLiquidity: true, // 加入時にトランチ登録
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true, // 価格追跡
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /* ───────────────────────── hookData エンコード ───────────────────────── */

    /// @notice LP がフロントから渡す hookData の組み立てヘルパ。
    function encodeHookData(address lp, Tranche tranche, uint256 principal) external pure returns (bytes memory) {
        return abi.encode(lp, tranche, principal);
    }

    function _decodeHookData(bytes calldata hookData)
        internal
        pure
        returns (address lp, Tranche tranche, uint256 principal)
    {
        (lp, tranche, principal) = abi.decode(hookData, (address, Tranche, uint256));
    }

    /* ───────────────────────── afterAddLiquidity: 登録 ───────────────────────── */

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) {
            return (BaseHook.afterAddLiquidity.selector, delta);
        }

        (address lp, Tranche tranche, uint256 principal) = _decodeHookData(hookData);
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        positions[poolId][lp] = LpPosition({
            owner: lp, tranche: tranche, principal: principal, sqrtPriceEntryX96: sqrtPriceX96, active: true
        });

        PoolAccount storage acct = poolAccounts[poolId];
        if (acct.sqrtPriceLastX96 == 0) {
            acct.sqrtPriceLastX96 = sqrtPriceX96;
        }
        if (tranche == Tranche.JUNIOR) {
            acct.juniorCapital += principal;
            acct.juniorPrincipalTotal += principal;
        } else {
            acct.seniorCapital += principal;
            acct.seniorPrincipalTotal += principal;
        }

        emit PositionOpened(poolId, lp, tranche, principal, sqrtPriceX96);
        return (BaseHook.afterAddLiquidity.selector, delta);
    }

    /* ───────────────────────── afterSwap: 価格追跡 ───────────────────────── */

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        poolAccounts[poolId].sqrtPriceLastX96 = sqrtPriceX96;
        return (BaseHook.afterSwap.selector, 0);
    }

    /* ───────────────────────── beforeRemoveLiquidity: 充当 ───────────────────────── */

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        if (hookData.length == 0) {
            return BaseHook.beforeRemoveLiquidity.selector;
        }

        (address lp,,) = _decodeHookData(hookData);
        PoolId poolId = key.toId();
        LpPosition storage pos = positions[poolId][lp];

        if (pos.owner == address(0)) revert NoPosition();
        if (!pos.active) revert PositionInactive();

        PoolAccount storage acct = poolAccounts[poolId];
        uint160 sqrtNow = acct.sqrtPriceLastX96;

        // 実現 IL（割合 WAD）と損失額（トークン）
        uint256 ilWad = ILMath.ilFromSqrtPrices(pos.sqrtPriceEntryX96, sqrtNow);
        uint256 ilLoss = ILMath.ilAmount(pos.principal, ilWad);

        uint256 lossBorne;
        uint256 payout;

        if (pos.tranche == Tranche.SENIOR) {
            // buffer 額 = principal * BUFFER_WAD
            uint256 bufferAmount = ILMath.ilAmount(pos.principal, BUFFER_WAD);
            // Junior が肩代わりするのは IL のうち buffer まで
            uint256 absorbed = ilLoss <= bufferAmount ? ilLoss : bufferAmount;
            // Junior 資本が足りなければそこまで
            if (absorbed > acct.juniorCapital) absorbed = acct.juniorCapital;

            uint256 residual = ilLoss > absorbed ? ilLoss - absorbed : 0;

            acct.juniorCapital -= absorbed;
            // Senior が実際に負担するのは residual のみ
            lossBorne = residual;
            payout = pos.principal > residual ? pos.principal - residual : 0;

            if (acct.seniorCapital >= pos.principal) {
                acct.seniorCapital -= pos.principal;
            } else {
                acct.seniorCapital = 0;
            }
            acct.seniorPrincipalTotal -= _min(pos.principal, acct.seniorPrincipalTotal);

            emit WaterfallApplied(poolId, ilLoss, absorbed, residual);
        } else {
            // Junior: 自身の IL を全額負担
            lossBorne = ilLoss;
            payout = pos.principal > ilLoss ? pos.principal - ilLoss : 0;

            if (acct.juniorCapital >= pos.principal) {
                acct.juniorCapital -= pos.principal;
            } else {
                acct.juniorCapital = 0;
            }
            acct.juniorPrincipalTotal -= _min(pos.principal, acct.juniorPrincipalTotal);
        }

        pos.active = false;
        emit PositionClosed(poolId, lp, pos.tranche, ilWad, lossBorne, payout);

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /* ───────────────────────── view ヘルパ ───────────────────────── */

    /// @notice あるポジションの現在の実現 IL（割合 WAD）を見積もる（退出前の確認用）。
    function quoteRealizedIl(PoolId poolId, address lp) external view returns (uint256 ilWad, uint256 ilLoss) {
        LpPosition memory pos = positions[poolId][lp];
        if (pos.owner == address(0) || !pos.active) return (0, 0);
        uint160 sqrtNow = poolAccounts[poolId].sqrtPriceLastX96;
        ilWad = ILMath.ilFromSqrtPrices(pos.sqrtPriceEntryX96, sqrtNow);
        ilLoss = ILMath.ilAmount(pos.principal, ilWad);
    }

    function getPosition(PoolId poolId, address lp) external view returns (LpPosition memory) {
        return positions[poolId][lp];
    }

    function getPoolAccount(PoolId poolId) external view returns (PoolAccount memory) {
        return poolAccounts[poolId];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
