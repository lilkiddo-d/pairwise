// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILongAdapter} from "./interfaces/IAdapters.sol";
import {ISwapVenue} from "./interfaces/ISwapVenue.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title LongAdapter
/// @notice Spot long leg: buys and holds stock tokens on behalf of exactly one PairVault.
///         Deployed as an EIP-1167 clone per vault so positions are segregated.
///         Every swap is bounded by an oracle-derived minimum output and a deadline.
contract LongAdapter is Initializable, ReentrancyGuardUpgradeable, ILongAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    address public vault;
    IERC20 public usdg;
    ISwapVenue public venue;
    IPriceOracle public oracle;
    address public tokenA;
    address public tokenB;

    event Increased(address indexed token, uint256 usdgIn, uint256 tokensOut);
    event Decreased(address indexed token, uint256 tokensIn, uint256 usdgOut);

    error OnlyVault();
    error UnsupportedToken();
    error BadParam();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vault_,
        IERC20 usdg_,
        ISwapVenue venue_,
        IPriceOracle oracle_,
        address tokenA_,
        address tokenB_
    ) external initializer {
        if (vault_ == address(0) || tokenA_ == address(0) || tokenB_ == address(0)) revert BadParam();
        __ReentrancyGuard_init();
        vault = vault_;
        usdg = usdg_;
        venue = venue_;
        oracle = oracle_;
        tokenA = tokenA_;
        tokenB = tokenB_;
    }

    function increase(address token, uint256 usdgIn, uint256 maxSlippageBps, uint256 deadline)
        external
        onlyVault
        nonReentrant
        returns (uint256 tokensOut)
    {
        _checkToken(token);
        if (maxSlippageBps > MAX_SLIPPAGE_BPS || usdgIn == 0) revert BadParam();
        uint256 expected = oracle.convert(address(usdg), usdgIn, token);
        uint256 minOut = expected * (10_000 - maxSlippageBps) / 10_000;
        usdg.forceApprove(address(venue), usdgIn);
        tokensOut = venue.swapExactIn(address(usdg), token, usdgIn, minOut, address(this), deadline);
        emit Increased(token, usdgIn, tokensOut);
    }

    // slither: incorrect-equality: exact-zero checks are early returns on empty positions/supply, not equality on attacker-controlled balances
    // slither-disable-start incorrect-equality
    function decrease(address token, uint256 fractionWad, uint256 maxSlippageBps, uint256 deadline)
        external
        onlyVault
        nonReentrant
        returns (uint256 usdgOut)
    {
        _checkToken(token);
        if (maxSlippageBps > MAX_SLIPPAGE_BPS || fractionWad == 0 || fractionWad > WAD) revert BadParam();
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 amount = fractionWad == WAD ? bal : Math.mulDiv(bal, fractionWad, WAD);
        if (amount == 0) return 0;
        uint256 expected = oracle.convert(token, amount, address(usdg));
        uint256 minOut = expected * (10_000 - maxSlippageBps) / 10_000;
        IERC20(token).forceApprove(address(venue), amount);
        usdgOut = venue.swapExactIn(token, address(usdg), amount, minOut, vault, deadline);
        emit Decreased(token, amount, usdgOut);
    }
    // slither-disable-end incorrect-equality

    function setOracle(IPriceOracle oracle_) external onlyVault {
        if (address(oracle_) == address(0)) revert BadParam();
        oracle = oracle_;
    }

    // slither: incorrect-equality: exact-zero checks are early returns on empty positions/supply, not equality on attacker-controlled balances
    // slither-disable-start incorrect-equality
    function value(address token) external view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        return bal == 0 ? 0 : oracle.convert(token, bal, address(usdg));
    }
    // slither-disable-end incorrect-equality

    function balance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function _checkToken(address token) internal view {
        if (token != tokenA && token != tokenB) revert UnsupportedToken();
    }
}
