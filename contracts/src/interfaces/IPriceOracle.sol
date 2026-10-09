// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceOracle
/// @notice Swappable price source. All prices are USD per 1 whole token, scaled to 1e18.
interface IPriceOracle {
    /// @notice Validated (fresh, positive, within deviation bounds) USD price of `token`, 1e18-scaled.
    function getPrice(address token) external view returns (uint256 priceWad);

    /// @notice `amount` of `from` expressed in units of `to`, using validated prices for both.
    function convert(address from, uint256 amount, address to) external view returns (uint256);

    /// @notice Historical price at a specific Chainlink round, plus that round's timestamp. Used for trustless seeding.
    function getRoundPrice(address token, uint80 roundId) external view returns (uint256 priceWad, uint256 updatedAt);

    /// @notice True if `token` has a configured feed.
    function hasFeed(address token) external view returns (bool);
}
