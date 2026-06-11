// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {ILMath} from "./ILMath.sol";

/// @title TrancheHook
/// @notice Uniswap v4 hook that absorbs IL in a two-tranche waterfall: Senior is protected up to
///         a buffer B, with Junior capital (held in a shared fund) covering the shortfall.
///
/// Economic model — shared fund pool (equal tranches S:J = 1 assumed):
///   - Every swap fee is captured into a currency1 fund.
///   - alpha * F  -> juniorFundClaim  (Junior's collateral and reward)
///   - (1-alpha)*F -> seniorFeeClaim  (Senior's fee share)
///   - On Senior exit, absorbed = min(IL, B*V_HODL, juniorFundClaim) is drawn from juniorFundClaim.
///   - Payouts flow only from the fund to the LP; the hook never takes from the user on remove.
///
/// Feasibility condition (solve offline, inject as constructor args):
///   alpha = E[absorbed] / (2F) + 0.5    (when E[absorbed] < F)
///
/// IL accounting:
///   ilWad is a ratio relative to V_HODL_current, so ilLoss = ilWad * V_HODL_current.
///   V_HODL_current is computed by re-valuing the stored entry amounts at the EMA price.
///   This keeps the on-chain IL computation consistent with the Monte Carlo model.
///
/// Fee capture:
///   - Fees are taken in the swap's output currency: zeroForOne -> currency1 (alpha split,
///     funds Senior protection), oneForZero -> currency0 (principal pro-rata, no premium).
///   - This assumes exact-input swaps, where the unspecified currency the afterSwapReturnDelta
///     applies to is the output. exact-output swaps are out of scope.
///
/// Known limitations (MVP):
///   - IL and Senior protection are accounted in currency1 only; the currency0 fund pays fee
///     yield to both tranches but never IL protection.
///   - One position per LP; remove must be a full close of the registered range (enforced).
///   - Auth is sender == lp. Shared custodial router support requires PositionManager ownerOf delegation.
contract TrancheHook is BaseHook {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    /* ------------------------------------------------------------------ */
    /*  Types                                                               */
    /* ------------------------------------------------------------------ */

    enum Tranche {
        JUNIOR,
        SENIOR
    }

    struct LpPosition {
        address owner;
        Tranche tranche;
        uint128 amount0; // entry token0 quantity (for V_HODL_current revaluation)
        uint128 amount1; // entry token1 quantity
        uint128 liquidity; // registered liquidity (enforces full-close on remove)
        uint256 principal; // entry token1 value (weight for fee pro-rata)
        uint160 sqrtPriceEntryX96;
        int24 tickLower;
        int24 tickUpper;
        bool active;
    }

    struct PoolAccount {
        uint160 sqrtPriceEmaX96; // EMA price (manipulation-resistant reference)
        uint256 juniorPrincipalTotal;
        uint256 seniorPrincipalTotal;
        uint256 juniorFundClaim; // cumulative alpha*F minus Senior absorptions (currency1)
        uint256 seniorFeeClaim; // cumulative (1-alpha)*F (currency1)
        uint256 fundBalance; // actual currency1 tokens held by this hook
        // currency0 mirror: fees captured on oneForZero swaps. No protection is paid from this
        // leg, so it has no alpha premium — it is split pro-rata by principal (see _afterSwap).
        uint256 juniorFundClaim0;
        uint256 seniorFeeClaim0;
        uint256 fundBalance0; // actual currency0 tokens held by this hook
        bool initialized;
    }

    /* ------------------------------------------------------------------ */
    /*  State                                                               */
    /* ------------------------------------------------------------------ */

    uint256 public immutable BUFFER_WAD;
    uint256 public immutable ALPHA_WAD;

    /// @notice Extra fee rate (WAD) levied on top of the pool LP fee; this is the fund's revenue source.
    uint256 public immutable HOOK_FEE_WAD;

    /// @dev Larger window = more manipulation resistance, slower price tracking.
    uint256 internal constant EMA_WINDOW = 8;
    uint256 internal constant WAD = 1e18;

    mapping(PoolId => PoolAccount) public poolAccounts;
    mapping(PoolId => mapping(address => LpPosition)) public positions;

    /* ------------------------------------------------------------------ */
    /*  Events                                                              */
    /* ------------------------------------------------------------------ */

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
    event FeesAccrued(PoolId indexed poolId, uint256 toJunior, uint256 toSenior);

    /* ------------------------------------------------------------------ */
    /*  Errors                                                              */
    /* ------------------------------------------------------------------ */

    error NoPosition();
    error PositionInactive();
    error PositionAlreadyActive();
    error Unauthorized();
    error RangeMismatch();
    error PartialCloseNotAllowed();
    error InvalidParam();
    error FundInvariantBroken();

    /* ------------------------------------------------------------------ */
    /*  Constructor                                                         */
    /* ------------------------------------------------------------------ */

    constructor(IPoolManager _manager, uint256 _bufferWad, uint256 _alphaWad, uint256 _hookFeeWad) BaseHook(_manager) {
        // ALPHA_WAD > WAD  → toSenior = fee - toJunior underflows, breaking every fee-capturing swap.
        // HOOK_FEE_WAD > WAD → fee > outAbs, rejected by the PoolManager balance check.
        // BUFFER_WAD > WAD → bufferAmount always exceeds IL, making the waterfall economically unsound.
        if (_alphaWad > WAD || _hookFeeWad > WAD || _bufferWad > WAD) revert InvalidParam();
        BUFFER_WAD = _bufferWad;
        ALPHA_WAD = _alphaWad;
        HOOK_FEE_WAD = _hookFeeWad;
    }

    /* ------------------------------------------------------------------ */
    /*  Hook permissions                                                    */
    /* ------------------------------------------------------------------ */

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /* ------------------------------------------------------------------ */
    /*  hookData helpers                                                    */
    /* ------------------------------------------------------------------ */

    function encodeHookData(address lp, Tranche tranche) external pure returns (bytes memory) {
        return abi.encode(lp, tranche);
    }

    function _decodeHookData(bytes calldata hookData) internal pure returns (address lp, Tranche tranche) {
        (lp, tranche) = abi.decode(hookData, (address, Tranche));
    }

    /* ------------------------------------------------------------------ */
    /*  afterAddLiquidity — register position                               */
    /* ------------------------------------------------------------------ */

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) {
            return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        (address lp, Tranche tranche) = _decodeHookData(hookData);
        // Require the caller to be the declared LP to prevent hookData spoofing.
        // Shared custodial router support requires PositionManager ownerOf delegation (roadmap).
        if (lp != sender) revert Unauthorized();

        PoolId poolId = key.toId();
        if (positions[poolId][lp].active) revert PositionAlreadyActive();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // Derive principal from the actual PoolManager delta to prevent self-reported inflation.
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        uint256 amt0 = d0 < 0 ? uint256(uint128(-d0)) : 0;
        uint256 amt1 = d1 < 0 ? uint256(uint128(-d1)) : 0;
        uint256 principal = ILMath.depositValueInToken1(amt0, amt1, sqrtPriceX96);

        positions[poolId][lp] = LpPosition({
            owner: lp,
            tranche: tranche,
            amount0: uint128(amt0),
            amount1: uint128(amt1),
            liquidity: uint128(uint256(params.liquidityDelta)),
            principal: principal,
            sqrtPriceEntryX96: sqrtPriceX96,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            active: true
        });

        PoolAccount storage acct = poolAccounts[poolId];
        if (!acct.initialized) {
            acct.sqrtPriceEmaX96 = sqrtPriceX96;
            acct.initialized = true;
        }

        if (tranche == Tranche.JUNIOR) acct.juniorPrincipalTotal += principal;
        else acct.seniorPrincipalTotal += principal;

        emit PositionOpened(poolId, lp, tranche, principal, sqrtPriceX96);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /* ------------------------------------------------------------------ */
    /*  afterSwap — update price EMA and capture hook fee                  */
    /* ------------------------------------------------------------------ */

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        PoolAccount storage acct = poolAccounts[poolId];

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        acct.sqrtPriceEmaX96 = _updateEma(acct.sqrtPriceEmaX96, sqrtPriceX96);

        // Fees are taken in the swap's output (unspecified) currency. This assumes exact-input
        // swaps, which is the hook's standing assumption (see contract NatSpec).
        int128 hookFee = 0;
        if (params.zeroForOne) {
            // Output is currency1: capture with the alpha split (this leg funds Senior protection).
            int128 out1 = delta.amount1();
            uint256 outAbs = out1 < 0 ? uint256(uint128(-out1)) : uint256(uint128(out1));
            uint256 fee = (outAbs * HOOK_FEE_WAD) / WAD;

            if (fee > 0) {
                hookFee = int128(uint128(fee));
                // take() must precede state updates: v4's unlock delta accounting pairs
                // afterSwapReturnDelta with take(), and deferring take() causes CurrencyNotSettled.
                // Re-entrancy is blocked by the PoolManager lock, so this ordering is safe.
                key.currency1.take(poolManager, address(this), fee, false);

                uint256 toJunior = (fee * ALPHA_WAD) / WAD;
                uint256 toSenior = fee - toJunior;
                acct.juniorFundClaim += toJunior;
                acct.seniorFeeClaim += toSenior;
                acct.fundBalance += fee;
                emit FeesAccrued(poolId, toJunior, toSenior);
            }
        } else {
            // Output is currency0. This leg never pays IL protection, so there is no premium to
            // earn: split pro-rata by principal (equal tranches => ~50/50), not by alpha.
            int128 out0 = delta.amount0();
            uint256 outAbs = out0 < 0 ? uint256(uint128(-out0)) : uint256(uint128(out0));
            uint256 fee = (outAbs * HOOK_FEE_WAD) / WAD;

            if (fee > 0) {
                hookFee = int128(uint128(fee));
                key.currency0.take(poolManager, address(this), fee, false);

                uint256 tot = acct.juniorPrincipalTotal + acct.seniorPrincipalTotal;
                uint256 toJunior = tot == 0 ? fee / 2 : (fee * acct.juniorPrincipalTotal) / tot;
                uint256 toSenior = fee - toJunior;
                acct.juniorFundClaim0 += toJunior;
                acct.seniorFeeClaim0 += toSenior;
                acct.fundBalance0 += fee;
                emit FeesAccrued(poolId, toJunior, toSenior);
            }
        }

        return (BaseHook.afterSwap.selector, hookFee);
    }

    /* ------------------------------------------------------------------ */
    /*  afterRemoveLiquidity — waterfall settlement                         */
    /* ------------------------------------------------------------------ */

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) {
            return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        (address lp,) = _decodeHookData(hookData);
        if (lp != sender) revert Unauthorized();

        PoolId poolId = key.toId();
        LpPosition storage pos = positions[poolId][lp];

        if (pos.owner == address(0)) revert NoPosition();
        if (!pos.active) revert PositionInactive();

        // Enforce full-close: a partial or wrong-range remove must not trigger a full payout
        // and set active = false, which would drain the fund and lock the real position.
        if (params.tickLower != pos.tickLower || params.tickUpper != pos.tickUpper) revert RangeMismatch();
        if (uint256(-params.liquidityDelta) != pos.liquidity) revert PartialCloseNotAllowed();

        PoolAccount storage acct = poolAccounts[poolId];

        uint256 ilWad = ILMath.ilFromSqrtPrices(
            pos.sqrtPriceEntryX96,
            acct.sqrtPriceEmaX96,
            TickMath.getSqrtPriceAtTick(pos.tickLower),
            TickMath.getSqrtPriceAtTick(pos.tickUpper)
        );
        // ilWad is a ratio relative to V_HODL_current, so multiply by V_HODL_current for the
        // absolute loss. Re-value entry amounts at the EMA price to get V_HODL_current.
        uint256 vHodlCur = ILMath.depositValueInToken1(pos.amount0, pos.amount1, acct.sqrtPriceEmaX96);
        uint256 ilLoss = ILMath.ilAmount(vHodlCur, ilWad);

        uint256 lossBorne;
        uint256 fundPayout; // currency1 payout (fee share + any protection)
        uint256 fundPayout0; // currency0 payout (fee share only)

        if (pos.tranche == Tranche.SENIOR) {
            // Junior fund covers up to min(IL, B * V_HODL_current, juniorFundClaim).
            uint256 bufferAmount = ILMath.ilAmount(vHodlCur, BUFFER_WAD);
            uint256 absorbed = ilLoss <= bufferAmount ? ilLoss : bufferAmount;
            if (absorbed > acct.juniorFundClaim) absorbed = acct.juniorFundClaim;
            acct.juniorFundClaim -= absorbed;

            uint256 residual = ilLoss > absorbed ? ilLoss - absorbed : 0;
            lossBorne = residual;

            // Both fee shares use the principal denominator before it is decremented below.
            uint256 feeShare =
                acct.seniorPrincipalTotal == 0 ? 0 : (acct.seniorFeeClaim * pos.principal) / acct.seniorPrincipalTotal;
            uint256 feeShare0 =
                acct.seniorPrincipalTotal == 0 ? 0 : (acct.seniorFeeClaim0 * pos.principal) / acct.seniorPrincipalTotal;
            acct.seniorFeeClaim -= feeShare;
            acct.seniorFeeClaim0 -= feeShare0;

            fundPayout = absorbed + feeShare;
            fundPayout0 = feeShare0;
            acct.seniorPrincipalTotal -= _min(pos.principal, acct.seniorPrincipalTotal);

            emit WaterfallApplied(poolId, ilLoss, absorbed, residual);
        } else {
            // Junior bears its own IL. Receives pro-rata share of remaining juniorFundClaim
            // (accumulated alpha*F minus any Senior absorptions already drawn).
            lossBorne = ilLoss;
            uint256 feeShare =
                acct.juniorPrincipalTotal == 0 ? 0 : (acct.juniorFundClaim * pos.principal) / acct.juniorPrincipalTotal;
            uint256 feeShare0 = acct.juniorPrincipalTotal == 0
                ? 0
                : (acct.juniorFundClaim0 * pos.principal) / acct.juniorPrincipalTotal;
            acct.juniorFundClaim -= feeShare;
            acct.juniorFundClaim0 -= feeShare0;

            fundPayout = feeShare;
            fundPayout0 = feeShare0;
            acct.juniorPrincipalTotal -= _min(pos.principal, acct.juniorPrincipalTotal);
        }

        // CEI: mark inactive before the external settle call.
        pos.active = false;

        // The invariant {junior,senior} claims == fundBalance per currency guarantees the held
        // balance covers each payout. A breach signals a bug elsewhere; revert to avoid silent
        // inconsistency.
        if (fundPayout > acct.fundBalance) revert FundInvariantBroken();
        if (fundPayout0 > acct.fundBalance0) revert FundInvariantBroken();

        int128 hookD0 = 0;
        int128 hookD1 = 0;
        if (fundPayout0 > 0) {
            acct.fundBalance0 -= fundPayout0;
            key.currency0.settle(poolManager, address(this), fundPayout0, false);
            hookD0 = -int128(uint128(fundPayout0));
        }
        if (fundPayout > 0) {
            acct.fundBalance -= fundPayout;
            key.currency1.settle(poolManager, address(this), fundPayout, false);
            hookD1 = -int128(uint128(fundPayout));
        }

        emit PositionClosed(poolId, lp, pos.tranche, ilWad, lossBorne, fundPayout);

        return (BaseHook.afterRemoveLiquidity.selector, toBalanceDelta(hookD0, hookD1));
    }

    /* ------------------------------------------------------------------ */
    /*  Internal helpers                                                    */
    /* ------------------------------------------------------------------ */

    /// @dev Integer EMA: ema' = (ema * (W-1) + price) / W
    function _updateEma(uint160 ema, uint160 price) internal pure returns (uint160) {
        if (ema == 0) return price;
        uint256 next = (uint256(ema) * (EMA_WINDOW - 1) + uint256(price)) / EMA_WINDOW;
        return uint160(next);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /* ------------------------------------------------------------------ */
    /*  View functions                                                      */
    /* ------------------------------------------------------------------ */

    function quoteRealizedIl(PoolId poolId, address lp) external view returns (uint256 ilWad, uint256 ilLoss) {
        LpPosition memory pos = positions[poolId][lp];
        if (pos.owner == address(0) || !pos.active) return (0, 0);
        uint160 emaP = poolAccounts[poolId].sqrtPriceEmaX96;
        ilWad = ILMath.ilFromSqrtPrices(
            pos.sqrtPriceEntryX96,
            emaP,
            TickMath.getSqrtPriceAtTick(pos.tickLower),
            TickMath.getSqrtPriceAtTick(pos.tickUpper)
        );
        uint256 vHodlCur = ILMath.depositValueInToken1(pos.amount0, pos.amount1, emaP);
        ilLoss = ILMath.ilAmount(vHodlCur, ilWad);
    }

    function getPosition(PoolId poolId, address lp) external view returns (LpPosition memory) {
        return positions[poolId][lp];
    }

    function getPoolAccount(PoolId poolId) external view returns (PoolAccount memory) {
        return poolAccounts[poolId];
    }
}
