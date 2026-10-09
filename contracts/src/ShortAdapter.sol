// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    IMorpho,
    IMorphoOracle,
    IIrm,
    IMorphoFlashLoanCallback,
    IMorphoSupplyCollateralCallback,
    Id,
    MarketParams,
    Market
} from "./interfaces/external/IMorpho.sol";
import {IShortAdapter} from "./interfaces/IAdapters.sol";
import {ISwapVenue} from "./interfaces/ISwapVenue.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title ShortAdapter
/// @notice Short leg on Morpho Blue for exactly one PairVault (EIP-1167 clone per vault):
///         post USDG (optionally wrapped in a USDG ERC-4626 such as steakUSDG) as collateral, borrow the stock
///         token, sell it for USDG and re-post the proceeds as collateral.
///         Unwinds buy back the exact debt (exact-output swap), repay by shares, release collateral pro-rata.
///         USDG supplied by the vault is used first; any shortfall is flash-borrowed from Morpho (fee-free) inside
///         the same transaction, so unwinds never depend on the long leg's proceeds.
contract ShortAdapter is
    Initializable,
    ReentrancyGuardUpgradeable,
    IShortAdapter,
    IMorphoFlashLoanCallback,
    IMorphoSupplyCollateralCallback
{
    using SafeERC20 for IERC20;

    struct MarketConfig {
        MarketParams params;
        Id id;
        IERC4626 wrapper; // address(0) when collateral is USDG itself
    }

    struct Open {
        address token;
        uint256 qty;
        uint256 minOut;
        uint256 usdgToPost;
        uint256 deadline;
    }

    struct Unwind {
        address token;
        uint256 repayShares;
        uint256 repayAssets;
        uint256 collateralOut;
        uint256 maxIn;
        uint256 deadline;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    address public vault;
    IMorpho public morpho;
    IERC20 public usdg;
    ISwapVenue public venue;
    IPriceOracle public oracle;
    mapping(address token => MarketConfig) internal _markets;
    uint8 internal _callback; // 0 none, 1 flash loan expected, 2 supply-collateral callback expected

    uint8 internal constant CB_NONE = 0;
    uint8 internal constant CB_FLASH = 1;
    uint8 internal constant CB_SUPPLY = 2;

    event Increased(address indexed token, uint256 borrowed, uint256 proceeds, uint256 margin);
    event Decreased(address indexed token, uint256 repaidAssets, uint256 collateralReleased, uint256 usdgOut);
    event CollateralAdded(address indexed token, uint256 usdgAmount);

    error OnlyVault();
    error UnsupportedToken();
    error BadMarket();
    error BadParam();
    error UnauthorizedCallback();
    error InsufficientFunds(uint256 available, uint256 required);

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vault_,
        IMorpho morpho_,
        IERC20 usdg_,
        ISwapVenue venue_,
        IPriceOracle oracle_,
        address tokenA,
        Id marketA,
        address tokenB,
        Id marketB
    ) external initializer {
        if (vault_ == address(0) || address(morpho_) == address(0)) revert BadParam();
        __ReentrancyGuard_init();
        vault = vault_;
        morpho = morpho_;
        usdg = usdg_;
        venue = venue_;
        oracle = oracle_;
        _setMarket(tokenA, marketA);
        _setMarket(tokenB, marketB);
    }

    function _setMarket(address token, Id id) internal {
        (address loan, address coll, address orc, address irm, uint256 lltv_) = morpho.idToMarketParams(id);
        if (loan != token || loan == address(0) || lltv_ == 0 || lltv_ >= WAD || orc == address(0)) revert BadMarket();
        IERC4626 wrapper = IERC4626(address(0));
        if (coll != address(usdg)) {
            if (IERC4626(coll).asset() != address(usdg)) revert BadMarket();
            wrapper = IERC4626(coll);
        }
        _markets[token] = MarketConfig({
            params: MarketParams({loanToken: loan, collateralToken: coll, oracle: orc, irm: irm, lltv: lltv_}),
            id: id,
            wrapper: wrapper
        });
    }

    // ---------------------------------------------------------------- mutations

    /// @dev Atomic leverage via Morpho's supply-collateral callback: Morpho credits `margin + minProceeds` of
    ///      collateral first, the callback borrows and sells the stock token, then Morpho pulls the collateral.
    ///      Any execution surplus above the minimum is posted as extra collateral afterwards.
    function increase(address token, uint256 notionalUsdg, uint256 marginUsdg, uint256 maxSlippageBps, uint256 deadline)
        external
        onlyVault
        nonReentrant
    {
        MarketConfig storage m = _market(token);
        if (maxSlippageBps > MAX_SLIPPAGE_BPS || notionalUsdg == 0) revert BadParam();

        // slither-disable-next-line uninitialized-local
        Open memory o;
        o.token = token;
        o.qty = oracle.convert(address(usdg), notionalUsdg, token);
        o.minOut = notionalUsdg * (10_000 - maxSlippageBps) / 10_000;
        o.usdgToPost = marginUsdg + o.minOut;
        o.deadline = deadline;
        uint256 collAssets =
            address(m.wrapper) == address(0) ? o.usdgToPost : m.wrapper.previewDeposit(o.usdgToPost);

        _callback = CB_SUPPLY;
        morpho.supplyCollateral(m.params, collAssets, address(this), abi.encode(o));
        _callback = CB_NONE;

        // post the execution surplus (proceeds above minOut, wrapper rounding) as extra collateral
        uint256 extra = usdg.balanceOf(address(this));
        if (extra != 0) _postCollateral(m, extra);
        if (address(m.wrapper) != address(0)) {
            uint256 dust = m.wrapper.balanceOf(address(this));
            if (dust != 0) {
                IERC20(address(m.wrapper)).forceApprove(address(morpho), dust);
                morpho.supplyCollateral(m.params, dust, address(this), "");
            }
        }
        emit Increased(token, o.qty, notionalUsdg, marginUsdg);
    }

    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function onMorphoSupplyCollateral(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho) || _callback != CB_SUPPLY) revert UnauthorizedCallback();
        Open memory o = abi.decode(data, (Open));
        MarketConfig storage m = _markets[o.token];
        morpho.borrow(m.params, o.qty, 0, address(this), address(this));
        IERC20(o.token).forceApprove(address(venue), o.qty);
        venue.swapExactIn(o.token, address(usdg), o.qty, o.minOut, address(this), o.deadline);
        if (address(m.wrapper) != address(0)) {
            usdg.forceApprove(address(m.wrapper), o.usdgToPost);
            m.wrapper.deposit(o.usdgToPost, address(this));
        }
        IERC20(m.params.collateralToken).forceApprove(address(morpho), assets);
    }
    // slither-disable-end unused-return

    function addCollateral(address token, uint256 usdgAmount) external onlyVault nonReentrant {
        MarketConfig storage m = _market(token);
        if (usdgAmount == 0) revert BadParam();
        _postCollateral(m, usdgAmount);
        emit CollateralAdded(token, usdgAmount);
    }

    function decrease(address token, uint256 fractionWad, uint256 maxSlippageBps, uint256 deadline)
        external
        onlyVault
        nonReentrant
        returns (uint256 usdgOut)
    {
        return _decrease(token, fractionWad, true, maxSlippageBps, deadline);
    }

    function deleverage(address token, uint256 fractionWad, uint256 maxSlippageBps, uint256 deadline)
        external
        onlyVault
        nonReentrant
        returns (uint256 usdgOut)
    {
        return _decrease(token, fractionWad, false, maxSlippageBps, deadline);
    }

    function setOracle(IPriceOracle oracle_) external onlyVault {
        if (address(oracle_) == address(0)) revert BadParam();
        oracle = oracle_;
    }

    function _decrease(
        address token,
        uint256 fractionWad,
        bool releaseCollateral,
        uint256 maxSlippageBps,
        uint256 deadline
    ) internal returns (uint256 usdgOut) {
        MarketConfig storage m = _market(token);
        if (maxSlippageBps > MAX_SLIPPAGE_BPS || fractionWad == 0 || fractionWad > WAD) revert BadParam();
        Unwind memory u = _plan(m, token, fractionWad, releaseCollateral, maxSlippageBps);
        u.deadline = deadline;

        uint256 bal = usdg.balanceOf(address(this));
        if (u.maxIn > bal) {
            // Without releasing collateral there is nothing to repay a flash loan with.
            if (!releaseCollateral) revert InsufficientFunds(bal, u.maxIn);
            _callback = CB_FLASH;
            morpho.flashLoan(address(usdg), u.maxIn - bal, abi.encode(u));
            _callback = CB_NONE;
        } else {
            _unwind(m, u);
        }

        usdgOut = usdg.balanceOf(address(this));
        if (usdgOut != 0) usdg.safeTransfer(vault, usdgOut);
        emit Decreased(token, u.repayAssets, u.collateralOut, usdgOut);
    }

    /// @dev Accrues interest and sizes the unwind: shares to repay, exact assets owed, collateral to release, max USDG in.
    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function _plan(
        MarketConfig storage m,
        address token,
        uint256 fractionWad,
        bool releaseCollateral,
        uint256 maxSlippageBps
    ) internal returns (Unwind memory u) {
        morpho.accrueInterest(m.params);
        (, uint128 borrowShares, uint128 collateral) = morpho.position(m.id, address(this));
        u.token = token;
        u.repayShares = fractionWad == WAD ? borrowShares : Math.mulDiv(borrowShares, fractionWad, WAD);
        if (releaseCollateral) {
            u.collateralOut = fractionWad == WAD ? collateral : Math.mulDiv(collateral, fractionWad, WAD);
        }
        if (u.repayShares != 0) {
            (,, uint128 tba, uint128 tbs,,) = morpho.market(m.id);
            u.repayAssets = _toAssetsUp(u.repayShares, tba, tbs);
            u.maxIn = oracle.convert(token, u.repayAssets, address(usdg)) * (10_000 + maxSlippageBps) / 10_000 + 1;
        }
    }
    // slither-disable-end unused-return

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho) || _callback != CB_FLASH) revert UnauthorizedCallback();
        Unwind memory u = abi.decode(data, (Unwind));
        _unwind(_markets[u.token], u);
        usdg.forceApprove(address(morpho), assets);
    }

    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function _unwind(MarketConfig storage m, Unwind memory u) internal {
        if (u.repayShares != 0) {
            usdg.forceApprove(address(venue), u.maxIn);
            venue.swapExactOut(address(usdg), u.token, u.repayAssets, u.maxIn, address(this), u.deadline);
            usdg.forceApprove(address(venue), 0);
            IERC20(u.token).forceApprove(address(morpho), u.repayAssets);
            morpho.repay(m.params, 0, u.repayShares, address(this), "");
        }
        if (u.collateralOut != 0) {
            morpho.withdrawCollateral(m.params, u.collateralOut, address(this), address(this));
            if (address(m.wrapper) != address(0)) m.wrapper.redeem(u.collateralOut, address(this), address(this));
        }
    }
    // slither-disable-end unused-return

    function _postCollateral(MarketConfig storage m, uint256 usdgAmount) internal {
        uint256 assets = usdgAmount;
        if (address(m.wrapper) != address(0)) {
            usdg.forceApprove(address(m.wrapper), usdgAmount);
            assets = m.wrapper.deposit(usdgAmount, address(this));
        }
        IERC20(m.params.collateralToken).forceApprove(address(morpho), assets);
        morpho.supplyCollateral(m.params, assets, address(this), "");
    }

    // ---------------------------------------------------------------- views

    function supportsToken(address token) external view returns (bool) {
        return _markets[token].params.loanToken != address(0);
    }

    function marketConfig(address token) external view returns (MarketParams memory params, Id id, address wrapper) {
        MarketConfig storage m = _market(token);
        return (m.params, m.id, address(m.wrapper));
    }

    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function borrowedAssets(address token) public view returns (uint256) {
        MarketConfig storage m = _market(token);
        (, uint128 borrowShares,) = morpho.position(m.id, address(this));
        if (borrowShares == 0) return 0;
        Market memory mk = _expectedMarket(m);
        return _toAssetsUp(borrowShares, mk.totalBorrowAssets, mk.totalBorrowShares);
    }
    // slither-disable-end unused-return

    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function collateralBalance(address token) public view returns (uint256) {
        (,, uint128 collateral) = morpho.position(_market(token).id, address(this));
        return collateral;
    }
    // slither-disable-end unused-return

    // slither: incorrect-equality: exact-zero checks are early returns on empty positions/supply, not equality on attacker-controlled balances
    // slither-disable-start incorrect-equality
    function debtValue(address token) public view returns (uint256) {
        uint256 b = borrowedAssets(token);
        return b == 0 ? 0 : oracle.convert(token, b, address(usdg));
    }
    // slither-disable-end incorrect-equality

    function collateralValue(address token) public view returns (uint256) {
        MarketConfig storage m = _market(token);
        uint256 c = collateralBalance(token);
        if (c == 0) return 0;
        return address(m.wrapper) == address(0) ? c : m.wrapper.convertToAssets(c);
    }

    function equity(address token) external view returns (int256) {
        uint256 assets = collateralValue(token) + usdg.balanceOf(address(this));
        uint256 debt = debtValue(token);
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(assets) - int256(debt);
    }

    // slither: incorrect-equality: exact-zero checks are early returns on empty positions/supply, not equality on attacker-controlled balances
    // slither-disable-start incorrect-equality
    function ltv(address token) external view returns (uint256) {
        MarketConfig storage m = _market(token);
        uint256 borrowed = borrowedAssets(token);
        if (borrowed == 0) return 0;
        uint256 c = collateralBalance(token);
        uint256 collInLoan = Math.mulDiv(c, IMorphoOracle(m.params.oracle).price(), ORACLE_PRICE_SCALE);
        if (collInLoan == 0) return type(uint256).max;
        return Math.mulDiv(borrowed, WAD, collInLoan);
    }
    // slither-disable-end incorrect-equality

    function lltv(address token) external view returns (uint256) {
        return _market(token).params.lltv;
    }

    function capacityUsdg(address token) external view returns (uint256) {
        MarketConfig storage m = _market(token);
        Market memory mk = _expectedMarket(m);
        if (mk.totalSupplyAssets <= mk.totalBorrowAssets) return 0;
        return oracle.convert(token, mk.totalSupplyAssets - mk.totalBorrowAssets, address(usdg));
    }

    function borrowRatePerSecond(address token) public view returns (uint256) {
        MarketConfig storage m = _market(token);
        if (m.params.irm == address(0)) return 0;
        return IIrm(m.params.irm).borrowRateView(m.params, _rawMarket(m.id));
    }

    // ---------------------------------------------------------------- internals

    function _market(address token) internal view returns (MarketConfig storage m) {
        m = _markets[token];
        if (m.params.loanToken == address(0)) revert UnsupportedToken();
    }

    function _rawMarket(Id id) internal view returns (Market memory mk) {
        (mk.totalSupplyAssets, mk.totalSupplyShares, mk.totalBorrowAssets, mk.totalBorrowShares, mk.lastUpdate, mk.fee)
        = morpho.market(id);
    }

    /// @dev Market state with interest accrued up to now (mirrors MorphoBalancesLib, ignoring fee shares).
    function _expectedMarket(MarketConfig storage m) internal view returns (Market memory mk) {
        mk = _rawMarket(m.id);
        uint256 elapsed = block.timestamp - mk.lastUpdate;
        if (elapsed != 0 && mk.totalBorrowAssets != 0 && m.params.irm != address(0)) {
            uint256 rate = IIrm(m.params.irm).borrowRateView(m.params, mk);
            uint256 interest = Math.mulDiv(mk.totalBorrowAssets, _wTaylorCompounded(rate, elapsed), WAD);
            mk.totalBorrowAssets += uint128(interest);
            mk.totalSupplyAssets += uint128(interest);
        }
    }

    function _wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 first = x * n;
        uint256 second = Math.mulDiv(first, first, 2 * WAD);
        uint256 third = Math.mulDiv(second, first, 3 * WAD);
        return first + second + third;
    }

    function _toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return Math.mulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }
}
