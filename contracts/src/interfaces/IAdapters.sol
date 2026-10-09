// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";

/// @title ILongAdapter
/// @notice Holds the long stock-token leg for exactly one vault. USDG in / USDG out.
interface ILongAdapter {
    /// @notice Buys `token` with `usdgIn` USDG previously transferred to the adapter.
    function increase(address token, uint256 usdgIn, uint256 maxSlippageBps, uint256 deadline)
        external
        returns (uint256 tokensOut);

    /// @notice Sells `fractionWad` (1e18 = 100%) of the held `token`; USDG is sent to the vault.
    function decrease(address token, uint256 fractionWad, uint256 maxSlippageBps, uint256 deadline)
        external
        returns (uint256 usdgOut);

    /// @notice Oracle value of the held `token`, in USDG units.
    function value(address token) external view returns (uint256);

    function balance(address token) external view returns (uint256);

    function setOracle(IPriceOracle oracle_) external;
}

/// @title IShortAdapter
/// @notice Holds the short stock-token leg for exactly one vault (borrow-and-sell on a lending venue).
interface IShortAdapter {
    /// @notice Posts `marginUsdg` as collateral, borrows `notionalUsdg` worth of `token` and sells it,
    ///         re-posting the proceeds as collateral. USDG must be transferred to the adapter beforehand.
    function increase(address token, uint256 notionalUsdg, uint256 marginUsdg, uint256 maxSlippageBps, uint256 deadline)
        external;

    /// @notice Buys back and repays `fractionWad` of the debt and releases the same fraction of collateral.
    ///         Any USDG held by the adapter (e.g. sent by the vault) is used first; shortfalls are flash-borrowed.
    ///         All remaining USDG is returned to the vault.
    function decrease(address token, uint256 fractionWad, uint256 maxSlippageBps, uint256 deadline)
        external
        returns (uint256 usdgOut);

    /// @notice Buys back and repays `fractionWad` of the debt WITHOUT releasing collateral (lowers LTV).
    ///         Must be fully funded by USDG already held by the adapter (no flash loan).
    function deleverage(address token, uint256 fractionWad, uint256 maxSlippageBps, uint256 deadline)
        external
        returns (uint256 usdgOut);

    function setOracle(IPriceOracle oracle_) external;

    /// @notice Adds USDG (already transferred) as collateral to lower LTV.
    function addCollateral(address token, uint256 usdgAmount) external;

    /// @notice Collateral value + idle USDG - debt value, in USDG units (can be negative after a liquidation-level move).
    function equity(address token) external view returns (int256);

    /// @notice Oracle value of the outstanding debt, in USDG units.
    function debtValue(address token) external view returns (uint256);

    /// @notice USDG value of posted collateral.
    function collateralValue(address token) external view returns (uint256);

    /// @notice Current loan-to-value as measured by the venue's own liquidation oracle, 1e18 = 100%.
    function ltv(address token) external view returns (uint256);

    /// @notice Venue liquidation LTV, 1e18-scaled.
    function lltv(address token) external view returns (uint256);

    /// @notice USDG value of borrowable `token` liquidity on the venue.
    function capacityUsdg(address token) external view returns (uint256);

    /// @notice Current borrow rate, per second, 1e18-scaled.
    function borrowRatePerSecond(address token) external view returns (uint256);

    function supportsToken(address token) external view returns (bool);
}
