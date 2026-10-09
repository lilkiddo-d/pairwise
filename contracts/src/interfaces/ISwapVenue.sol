// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISwapVenue
/// @notice Swappable spot execution venue. Pulls `tokenIn` from msg.sender; never holds funds between calls.
interface ISwapVenue {
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);

    /// @dev Unused `tokenIn` is refunded to msg.sender.
    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountIn);

    function hasRoute(address tokenIn, address tokenOut) external view returns (bool);
}
