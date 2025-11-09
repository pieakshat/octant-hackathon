// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol"; 
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IAaveStrategy} from "../interfaces/IAaveStrategy.sol";

struct DirectSwapContext {
    bool isExactInput;
    uint256 amountIn;
    uint256 amountOut;
    address currencyIn;
    address currencyOut;
}

contract CoWHook is BaseHook {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct PendingSwap {
        address strategyIn;
        address currencyIn;
        address currencyOut;
        uint256 depositAmount;
        uint256 feeAmount;
        uint256 totalInputAmount;
        uint256 amountOut;
    }

    error StrategyNotConfigured();
    error InvalidStrategyAddress();
    error StrategyAssetMismatch();
    error NotGovernance();
    error UnsupportedSwapDirection();
    error SwapAmountTooLarge();
    error InsufficientStrategyLiquidity();
    error PendingSwapExists();

    uint256 public constant MIN_SWAP_SIZE = 1000 * 10**6; // 1000 USDC
    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant HOOK_FEE_BPS = 50; // 0.5%

    address public immutable GOVERNANCE;

    mapping(address => IAaveStrategy) public strategies;
    mapping(bytes32 => PendingSwap) private pendingSwaps;

    event StrategyConfigured(address indexed token, address indexed strategy);
    event FeeCollected(address indexed token, uint256 amount);

    constructor(IPoolManager _manager) BaseHook(_manager) {
        GOVERNANCE = msg.sender;    // address that will receive the fees collected from Market making 
    }

    /// @notice Get the total managed assets for the two tokens of the pair
    /// @param tokenA The address of the first token of the pair
    /// @param tokenB The address of the second token of the pair
    /// @return tokenAAssets The total managed assets for the first token of the pair
    /// @return tokenBAssets The total managed assets for the second token of the pair
    function getTotalManagedAssets(address tokenA, address tokenB)
        external
        view
        returns (uint256 tokenAAssets, uint256 tokenBAssets)
    {
        IAaveStrategy strategyA = strategies[tokenA];
        IAaveStrategy strategyB = strategies[tokenB];

        if (address(strategyA) != address(0)) {
            tokenAAssets = strategyA.totalManagedAssets();
        }

        if (address(strategyB) != address(0)) {
            tokenBAssets = strategyB.totalManagedAssets();
        }
    }

    /// @notice Modifier to only allow the governance address to call the function
    modifier onlyGovernance() {
        _enforceGovernance();
        _;
    }

    /// @notice Enforce that the caller is the governance address
    function _enforceGovernance() internal view {
        if (msg.sender != GOVERNANCE) revert NotGovernance();
    }

    /// @notice Set the strategy via the governance address for a given token 
    /// @param token The address of the token to set the strategy for
    /// @param strategyAddress The address of the strategy to set for the token
    function setStrategyForToken(address token, address strategyAddress) external onlyGovernance {
        if (token == address(0)) revert InvalidStrategyAddress();

        if (strategyAddress == address(0)) {
            delete strategies[token];
            emit StrategyConfigured(token, address(0));
            return;
        }

        IAaveStrategy strategyInstance = IAaveStrategy(strategyAddress);
        if (strategyInstance.assetToken() != token) revert StrategyAssetMismatch();

        strategies[token] = strategyInstance;
        emit StrategyConfigured(token, strategyAddress);
    }

    /// @notice Get the permissions for the hook
    /// @return Permissions The permissions for the hook
    function getHookPermissions() 
    public pure override 
    returns (Hooks.Permissions memory) {
            return Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,  
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /// @notice Before swap hook, handles the logic for how to execute the swap 
    /// @param sender The address of the sender
    /// @param key The key of the pool
    /// @param params The parameters of the swap
        function _beforeSwap(
        address sender, 
        PoolKey calldata key, 
        SwapParams calldata params, 
        bytes calldata 
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        
        DirectSwapContext memory ctx;

        {
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

            ctx.isExactInput = params.amountSpecified < 0;
            if (ctx.isExactInput) {
                ctx.amountIn = uint256(-params.amountSpecified);
                ctx.amountOut = calculateOutputAmount(sqrtPriceX96, ctx.amountIn, params.zeroForOne);
            } else {
                ctx.amountOut = uint256(params.amountSpecified);
                ctx.amountIn = calculateInputAmount(sqrtPriceX96, ctx.amountOut, params.zeroForOne);
            }
        }

        ctx.currencyIn = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        ctx.currencyOut = Currency.unwrap(params.zeroForOne ? key.currency1 : key.currency0);

        // Check if swap is large enough to handle directly
        if (ctx.amountIn >= MIN_SWAP_SIZE) {
            return executeDirectSwap(sender, key, params, ctx);
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Execute the direct swap between user and the strategyVault
    /// @param sender The address of the sender
    /// @param key The key of the pool
    /// @param params The parameters of the swap
    /// @param ctx The context of the swap
    /// @return selector The selector of the hook
    /// @return delta The delta of the swap
    /// @return hookFee The hook fee of the swap
    function executeDirectSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        DirectSwapContext memory ctx
    )
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (ctx.currencyIn == ctx.currencyOut) revert UnsupportedSwapDirection();

        IAaveStrategy outStrategy = strategies[ctx.currencyOut];
        IAaveStrategy inStrategy = strategies[ctx.currencyIn];


        // The txn will directly revert instead of going through pool if it fails in executeDirectSwap
        // this is done intentionally so that the user swapping the large amount doesn't go through the pool unexpectedly
        if (address(outStrategy) == address(0) || address(inStrategy) == address(0)) {
            revert StrategyNotConfigured();
        }

        uint256 available = outStrategy.getAvailableLiquidityForSwap();
        if (available < ctx.amountOut) {
            revert InsufficientStrategyLiquidity();
        }

        uint256 withdrawn = outStrategy.pullFundsForSwap(ctx.amountOut, 0);
        if (withdrawn < ctx.amountOut) {
            revert InsufficientStrategyLiquidity();
        }

        uint256 surplus = withdrawn - ctx.amountOut;
        if (surplus > 0) {
            _depositIntoStrategy(outStrategy, ctx.currencyOut, surplus);
        }

        uint256 fee = _calculateFee(ctx.amountIn);
        uint256 depositAmount = ctx.amountIn - fee;

        if (ctx.amountIn > 0) {
            bytes32 swapKey = _computeSwapKey(sender, key, params);

            if (pendingSwaps[swapKey].currencyIn != address(0)) {
                revert PendingSwapExists();
            }

            pendingSwaps[swapKey] = PendingSwap({
                strategyIn: address(inStrategy),
                currencyIn: ctx.currencyIn,
                currencyOut: ctx.currencyOut,
                depositAmount: depositAmount,
                feeAmount: fee,
                totalInputAmount: ctx.amountIn,
                amountOut: ctx.amountOut
            });
        }

        return _buildDelta(ctx);
    }

    /// @notice Compute the swap key
    /// @param sender The address of the sender
    /// @param key The key of the pool
    /// @param params The parameters of the swap
    /// @return swapKey The key of the swap
    function _computeSwapKey(address sender, PoolKey calldata key, SwapParams calldata params)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                sender,
                key.currency0,
                key.currency1,
                key.fee,
                key.tickSpacing,
                key.hooks,
                params.zeroForOne,
                params.amountSpecified,
                params.sqrtPriceLimitX96
            )
        );
    }

    /// @notice Deposit into the strategyVault called after direct swap
    /// @param strategyRef The address of the strategy
    /// @param token The address of the token to deposit
    /// @param amount The amount of the token to deposit
    function _depositIntoStrategy(IAaveStrategy strategyRef, address token, uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        IERC20(token).safeTransfer(address(strategyRef), amount);
        strategyRef.pushAfterSwap(amount);
    }

    function _calculateFee(uint256 amount) internal pure returns (uint256) {
        return (amount * HOOK_FEE_BPS) / MAX_BPS;
    }


    function _buildDelta(DirectSwapContext memory ctx)
        internal
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (ctx.amountIn > uint256(type(uint256).max) || ctx.amountOut > uint256(type(uint256).max)) {
            revert SwapAmountTooLarge();
        }

        int128 deltaSpecified;
        int128 deltaUnspecified;

        if (ctx.isExactInput) {
            deltaSpecified = int256(ctx.amountIn).toInt128();
            deltaUnspecified = -int256(ctx.amountOut).toInt128();
        } else {
            deltaSpecified = -int256(ctx.amountOut).toInt128();
            deltaUnspecified = int256(ctx.amountIn).toInt128();
        }

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(deltaSpecified, deltaUnspecified), 0);
    }


    function calculateOutputAmount(
        uint160 sqrtPriceX96,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (uint256 amountOut) {
        // Price = (sqrtPriceX96 / 2^96)^2 = token1/token0
        // If zeroForOne: selling token0 for token1, so amountOut = amountIn * price
        // If oneForZero: selling token1 for token0, so amountOut = amountIn / price
        
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        
        if (zeroForOne) {
            amountOut = FullMath.mulDiv(amountIn, priceX192, 1 << 192);
        } else {
            
            amountOut = FullMath.mulDiv(amountIn, 1 << 192, priceX192);
        }
    }
    

    function calculateInputAmount(
        uint160 sqrtPriceX96,
        uint256 amountOut,
        bool zeroForOne
    ) internal pure returns (uint256 amountIn) {
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        
        if (zeroForOne) {
            
            amountIn = FullMath.mulDivRoundingUp(amountOut, 1 << 192, priceX192);
        } else {
            
            amountIn = FullMath.mulDivRoundingUp(amountOut, priceX192, 1 << 192);
        }
    }


    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        bytes32 swapKey = _computeSwapKey(sender, key, params);
        PendingSwap memory pending = pendingSwaps[swapKey];

        if (pending.currencyIn == address(0)) {
            return (IHooks.afterSwap.selector, 0);
        }

        delete pendingSwaps[swapKey];

        uint256 totalAmount = pending.totalInputAmount;
        if (totalAmount > 0) {
            poolManager.take(Currency.wrap(pending.currencyIn), address(this), totalAmount);

            if (pending.depositAmount > 0) {
                IERC20(pending.currencyIn).safeTransfer(pending.strategyIn, pending.depositAmount);
                IAaveStrategy(pending.strategyIn).pushAfterSwap(pending.depositAmount);
            }

            if (pending.feeAmount > 0) {
                IERC20(pending.currencyIn).safeTransfer(GOVERNANCE, pending.feeAmount);
                emit FeeCollected(pending.currencyIn, pending.feeAmount);
            }
        }

        if (pending.amountOut > 0) {
            Currency outCurrency = Currency.wrap(pending.currencyOut);
            poolManager.sync(outCurrency);
            IERC20(pending.currencyOut).safeTransfer(address(poolManager), pending.amountOut);
            poolManager.settle();
        }

        return (IHooks.afterSwap.selector, 0);
    }
}