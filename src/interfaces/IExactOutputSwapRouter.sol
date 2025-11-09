// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IExactOutputSwapRouter {
    /**
     * @notice Perform an exact-output swap
     * @param payer Address that provides the input tokens
     * @param inputToken Address of token used as swap input
     * @param outputToken Address of token to receive from the swap
     * @param amountOut Exact amount of `outputToken` to receive
     * @param maxAmountIn Maximum amount of `inputToken` willing to spend
     * @param recipient Address that receives the output tokens
     * @param data ABI-encoded routing data required by the router implementation
     * @return amountIn Actual amount of `inputToken` spent
     */
    function swapExactOutput(
        address payer,
        address inputToken,
        address outputToken,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        bytes calldata data
    ) external returns (uint256 amountIn);
}

