// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Uniswap SwapRouter02 (IV3SwapRouter) multi-hop entry points. Note: no deadline in the structs;
///         callers must enforce deadlines themselves.
interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}
