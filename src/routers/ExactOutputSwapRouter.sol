// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";

import {IExactOutputSwapRouter} from "../interfaces/IExactOutputSwapRouter.sol";

contract ExactOutputSwapRouter is SafeCallback, IExactOutputSwapRouter {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    error InvalidRoute();
    error SlippageExceeded();
    error UnsupportedCurrency();
    error ZeroAmount();

    struct Route {
        PoolKey poolKey;
        bool zeroForOne;
        bytes hookData;
    }

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey poolKey;
        Currency inputCurrency;
        Currency outputCurrency;
        bool zeroForOne;
        uint256 amountOut;
        uint256 maxAmountIn;
        bytes hookData;
    }

    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    function swapExactOutput(
        address payer,
        address inputToken,
        address outputToken,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        bytes calldata data
    ) external override returns (uint256 amountIn) {
        if (amountOut == 0 || maxAmountIn == 0) revert ZeroAmount();
        if (payer == address(0) || recipient == address(0)) revert InvalidRoute();

        Route memory route = abi.decode(data, (Route));

        Currency inputCurrency = route.zeroForOne ? route.poolKey.currency0 : route.poolKey.currency1;
        Currency outputCurrency = route.zeroForOne ? route.poolKey.currency1 : route.poolKey.currency0;

        if (
            Currency.unwrap(inputCurrency) != inputToken || Currency.unwrap(outputCurrency) != outputToken
                || Currency.unwrap(inputCurrency) == address(0) || Currency.unwrap(outputCurrency) == address(0)
        ) {
            revert InvalidRoute();
        }

        CallbackData memory callbackData = CallbackData({
            payer: payer,
            recipient: recipient,
            poolKey: route.poolKey,
            inputCurrency: inputCurrency,
            outputCurrency: outputCurrency,
            zeroForOne: route.zeroForOne,
            amountOut: amountOut,
            maxAmountIn: maxAmountIn,
            hookData: route.hookData
        });

        bytes memory result = poolManager.unlock(abi.encode(callbackData));
        amountIn = abi.decode(result, (uint256));
    }

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        SwapParams memory params = SwapParams({
            zeroForOne: data.zeroForOne,
            amountSpecified: int256(data.amountOut),
            sqrtPriceLimitX96: data.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = poolManager.swap(data.poolKey, params, data.hookData);

        (uint256 amountIn, uint256 amountOutReceived) = _parseSwapDelta(delta, data.zeroForOne);

        if (amountOutReceived < data.amountOut) revert SlippageExceeded();
        if (amountIn > data.maxAmountIn) revert SlippageExceeded();

        _settleInput(data.inputCurrency, data.payer, amountIn);
        _deliverOutput(data.outputCurrency, data.recipient, data.amountOut);

        return abi.encode(amountIn);
    }

    function _parseSwapDelta(BalanceDelta delta, bool zeroForOne)
        private
        pure
        returns (uint256 amountIn, uint256 amountOut)
    {
        int256 amount0 = int256(delta.amount0());
        int256 amount1 = int256(delta.amount1());

        if (zeroForOne) {
            if (amount0 >= 0 || amount1 <= 0) revert InvalidRoute();
            amountIn = uint256(-amount0);
            amountOut = uint256(amount1);
        } else {
            if (amount1 >= 0 || amount0 <= 0) revert InvalidRoute();
            amountIn = uint256(-amount1);
            amountOut = uint256(amount0);
        }
    }

    function _settleInput(Currency currency, address payer, uint256 amount) private {
        if (amount == 0) {
            return;
        }

        address token = Currency.unwrap(currency);
        if (token == address(0)) revert UnsupportedCurrency();

        poolManager.sync(currency);

        if (payer == address(this)) {
            IERC20(token).safeTransfer(address(poolManager), amount);
        } else {
            IERC20(token).safeTransferFrom(payer, address(poolManager), amount);
        }

        poolManager.settle();
    }

    function _deliverOutput(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) {
            return;
        }

        if (Currency.unwrap(currency) == address(0)) revert UnsupportedCurrency();

        poolManager.take(currency, recipient, amount);
    }
}

