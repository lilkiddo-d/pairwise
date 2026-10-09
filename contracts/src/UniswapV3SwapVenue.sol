// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter02} from "./interfaces/external/ISwapRouter02.sol";
import {ISwapVenue} from "./interfaces/ISwapVenue.sol";

/// @title UniswapV3SwapVenue
/// @notice ISwapVenue over Uniswap v3 SwapRouter02 with admin-configured multi-hop routes.
///         Stateless between calls: pulls tokenIn from the caller, pays tokenOut to `recipient`, refunds leftovers.
///         Slippage (minOut / maxIn) is computed by callers from the oracle; deadline is enforced here because
///         SwapRouter02's exactInput/exactOutput structs do not carry one.
contract UniswapV3SwapVenue is AccessControl, ReentrancyGuard, ISwapVenue {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_HOPS = 3;

    ISwapRouter02 public immutable router;
    mapping(address tokenIn => mapping(address tokenOut => bytes path)) public routes;

    event RouteSet(address indexed tokenIn, address indexed tokenOut, bytes path);
    event Swapped(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    error Expired();
    error NoRoute(address tokenIn, address tokenOut);
    error InvalidRoute();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error ZeroAmount();

    constructor(address admin, ISwapRouter02 router_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        router = router_;
    }

    /// @notice Sets the route tokens[0] -> ... -> tokens[n] and its reverse.
    function setRoute(address[] calldata tokens, uint24[] calldata fees) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 hops = fees.length;
        if (hops == 0 || hops > MAX_HOPS || tokens.length != hops + 1) revert InvalidRoute();
        bytes memory fwd = abi.encodePacked(tokens[0]);
        bytes memory rev = abi.encodePacked(tokens[hops]);
        for (uint256 i; i < hops; ++i) {
            if (tokens[i] == address(0) || tokens[i + 1] == address(0) || tokens[i] == tokens[i + 1]) {
                revert InvalidRoute();
            }
            fwd = abi.encodePacked(fwd, fees[i], tokens[i + 1]);
            rev = abi.encodePacked(rev, fees[hops - 1 - i], tokens[hops - 1 - i]);
        }
        routes[tokens[0]][tokens[hops]] = fwd;
        routes[tokens[hops]][tokens[0]] = rev;
        emit RouteSet(tokens[0], tokens[hops], fwd);
        emit RouteSet(tokens[hops], tokens[0], rev);
    }

    function hasRoute(address tokenIn, address tokenOut) external view returns (bool) {
        return routes[tokenIn][tokenOut].length != 0;
    }

    // slither: reentrancy-balance: balance-delta is the *measurement* of delivery; function is nonReentrant and the callee is a trusted, immutable protocol contract
    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start reentrancy-balance
    // slither-disable-start unused-return
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        bytes memory path = routes[tokenIn][tokenOut];
        if (path.length == 0) revert NoRoute(tokenIn, tokenOut);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(recipient);
        router.exactInput(
            ISwapRouter02.ExactInputParams({
                path: path, recipient: recipient, amountIn: amountIn, amountOutMinimum: minAmountOut
            })
        );
        amountOut = IERC20(tokenOut).balanceOf(recipient) - before;
        IERC20(tokenIn).forceApprove(address(router), 0);
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
    // slither-disable-end reentrancy-balance
    // slither-disable-end unused-return

    // slither: reentrancy-balance: balance-delta is the *measurement* of delivery; function is nonReentrant and the callee is a trusted, immutable protocol contract
    // slither-disable-start reentrancy-balance
    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountIn) {
        if (block.timestamp > deadline) revert Expired();
        if (amountOut == 0) revert ZeroAmount();
        // exactOutput paths are encoded tokenOut -> ... -> tokenIn
        bytes memory path = routes[tokenOut][tokenIn];
        if (path.length == 0) revert NoRoute(tokenIn, tokenOut);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), maxAmountIn);
        IERC20(tokenIn).forceApprove(address(router), maxAmountIn);
        uint256 before = IERC20(tokenOut).balanceOf(recipient);
        amountIn = router.exactOutput(
            ISwapRouter02.ExactOutputParams({
                path: path, recipient: recipient, amountOut: amountOut, amountInMaximum: maxAmountIn
            })
        );
        uint256 received = IERC20(tokenOut).balanceOf(recipient) - before;
        IERC20(tokenIn).forceApprove(address(router), 0);
        if (received < amountOut) revert InsufficientOutput(received, amountOut);
        uint256 leftover = IERC20(tokenIn).balanceOf(address(this));
        if (leftover != 0) IERC20(tokenIn).safeTransfer(msg.sender, leftover);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, received);
    }
    // slither-disable-end reentrancy-balance
}
