// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILongAdapter, IShortAdapter} from "./interfaces/IAdapters.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";
import {IPairVault, ISpreadOracle, IFeeCollector, IComplianceRegistry} from "./interfaces/IPairwise.sol";

/// @title PairVault
/// @notice ERC-4626 USDG vault running one market-neutral pairs trade (A vs B).
///         - FLAT: 100% USDG, deposits/withdrawals are plain cash at any time.
///         - LONG_SPREAD: long A (LongAdapter) / short B (ShortAdapter).  SHORT_SPREAD: the mirror.
///         Position changes are driven only by the StrategyEngine (keepers) and are followed by hard checks:
///         dollar-neutral band and short-leg LTV <= maxLtvBps * venue LLTV.
///         Withdrawals while in a position unwind both legs pro-rata in the same transaction; the redeemer bears
///         their own execution cost so remaining holders are never diluted.
///         Fees: management (<= 1%/yr) and performance (<= 15% over a high-water mark), minted as shares to the
///         FeeCollector. The caps are compile-time constants.
contract PairVault is
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IPairVault
{
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 100; // 1% / year, hard cap
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 1_500; // 15% of gains over HWM, hard cap
    uint256 public constant MAX_SLIPPAGE_BPS = 300;
    uint256 public constant MAX_EMERGENCY_SLIPPAGE_BPS = 500;
    uint256 public constant MAX_BAND_BPS = 2_000;
    uint256 public constant MIN_NOTIONAL = 10e6; // 10 USDG

    uint8 public constant EXIT_EMERGENCY = 7;
    uint8 public constant EXIT_FULL_REDEMPTION = 8;

    struct Config {
        uint16 maxSlippageBps; // per-swap tolerance vs oracle
        uint16 deployBps; // share of NAV committed at entry (rest is reserve)
        uint16 targetLtvBps; // entry LTV as share of venue LLTV
        uint16 rebalanceLtvBps; // keeper deleverages above this share of LLTV
        uint16 maxLtvBps; // hard cap (the "venue safe LTV") as share of LLTV
        uint16 bandBps; // dollar-neutral band: |L - S| <= band * max(L, S)
        uint16 rebalanceTriggerBps; // hedge drift that triggers a rebalance
        uint16 maxTiltBps; // max deviation of the hedge ratio from 1.0 used for sizing
        uint128 maxNotionalUsdg; // per-leg cap (0 = none)
        uint128 depositCap; // total assets cap (0 = none)
    }

    struct InitParams {
        IERC20 usdg;
        string name;
        string symbol;
        uint256 pairId;
        address tokenA;
        address tokenB;
        ILongAdapter longAdapter;
        IShortAdapter shortAdapter;
        IPriceOracle oracle;
        ISpreadOracle spreadOracle;
        IMarketClock clock;
        address engine;
        address feeCollector;
        address compliance;
        address admin;
        address guardian;
        Config config;
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
    }

    // ---------------------------------------------------------------- storage

    uint256 public pairId;
    address public tokenA;
    address public tokenB;
    ILongAdapter public longAdapter;
    IShortAdapter public shortAdapter;
    IPriceOracle public oracle;
    ISpreadOracle public spreadOracle;
    IMarketClock public clock;
    address public engine;
    address public feeCollector;
    IComplianceRegistry public compliance;
    Config public config;

    State public state;
    uint64 public entryTime;
    int256 public entryZ;
    uint256 public entryNav;
    int256 public netFlowsSinceEntry;

    uint16 public managementFeeBps;
    uint16 public performanceFeeBps;
    uint64 public lastFeeAccrual;
    uint256 public highWaterMark; // assets per share, 1e18-scaled (virtual-offset aware)

    // ---------------------------------------------------------------- events

    event Entered(
        State indexed direction, int256 z, uint256 longValue, uint256 shortValue, uint256 margin, uint256 nav
    );
    event Exited(uint8 indexed reason, int256 z, uint256 navAfter, int256 pnl);
    event Rebalanced(uint256 longValue, uint256 shortValue, uint256 ltv);
    event FeesAccrued(uint256 managementShares, uint256 performanceShares, uint256 highWaterMark);
    event ConfigSet(Config config);
    event FeesSet(uint16 managementFeeBps, uint16 performanceFeeBps);
    event FeeCollectorSet(address feeCollector);
    event ComplianceSet(address compliance);
    event EngineSet(address engine);
    event OracleSet(address oracle);

    // ---------------------------------------------------------------- errors

    error OnlyEngine();
    error BadState();
    error BadConfig();
    error MarketClosed();
    error NotAllowed(address account);
    error NotionalTooSmall(uint256 notional);
    error BandBreached(uint256 longValue, uint256 shortValue);
    error LtvTooHigh(uint256 ltv, uint256 maxLtv);
    error SlippageExceeded(uint256 assets, uint256 minAssets);

    modifier onlyEngine() {
        if (msg.sender != engine) revert OnlyEngine();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams memory p) external initializer {
        __ERC20_init(p.name, p.symbol);
        __ERC4626_init(p.usdg);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        pairId = p.pairId;
        tokenA = p.tokenA;
        tokenB = p.tokenB;
        longAdapter = p.longAdapter;
        shortAdapter = p.shortAdapter;
        oracle = p.oracle;
        spreadOracle = p.spreadOracle;
        clock = p.clock;
        engine = p.engine;
        feeCollector = p.feeCollector;
        compliance = IComplianceRegistry(p.compliance);
        _setConfig(p.config);
        _setFees(p.managementFeeBps, p.performanceFeeBps);
        lastFeeAccrual = uint64(block.timestamp);

        _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
        _grantRole(GUARDIAN_ROLE, p.guardian);
    }

    // ================================================================ admin (Timelock)

    function setConfig(Config calldata c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setConfig(c);
    }

    function setFees(uint16 mgmtBps, uint16 perfBps) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        (uint256 m, uint256 p) = _accrueFeesState(); // accrue at the old rates
        _setFees(mgmtBps, perfBps);
        _notifyFees(feeCollector, m, p);
    }

    function setFeeCollector(address fc) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        (uint256 m, uint256 p) = _accrueFeesState(); // settle with the old collector
        address old = feeCollector;
        feeCollector = fc;
        emit FeeCollectorSet(fc);
        _notifyFees(old, m, p);
    }

    function setCompliance(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IComplianceRegistry(registry);
        emit ComplianceSet(registry);
    }

    function setEngine(address engine_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        engine = engine_;
        emit EngineSet(engine_);
    }

    /// @notice Swaps the price oracle for the vault and both adapters in one step.
    function setOracle(IPriceOracle oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(oracle_) == address(0)) revert BadConfig();
        oracle = oracle_;
        longAdapter.setOracle(oracle_);
        shortAdapter.setOracle(oracle_);
        emit OracleSet(address(oracle_));
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _setConfig(Config memory c) internal {
        if (
            c.maxSlippageBps > MAX_SLIPPAGE_BPS || c.deployBps == 0 || c.deployBps > 9_500 || c.targetLtvBps == 0
                || c.targetLtvBps > c.rebalanceLtvBps || c.rebalanceLtvBps > c.maxLtvBps || c.maxLtvBps > 9_000
                || c.bandBps == 0 || c.bandBps > MAX_BAND_BPS || c.maxTiltBps >= c.bandBps
                || c.rebalanceTriggerBps == 0 || c.rebalanceTriggerBps >= c.bandBps
        ) revert BadConfig();
        config = c;
        emit ConfigSet(c);
    }

    function _setFees(uint16 mgmtBps, uint16 perfBps) internal {
        if (mgmtBps > MAX_MANAGEMENT_FEE_BPS || perfBps > MAX_PERFORMANCE_FEE_BPS) revert BadConfig();
        managementFeeBps = mgmtBps;
        performanceFeeBps = perfBps;
        emit FeesSet(mgmtBps, perfBps);
    }

    // ================================================================ strategy (StrategyEngine only)

    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function enter(State direction, int256 z, uint256 deadline) external onlyEngine nonReentrant whenNotPaused {
        if (state != State.FLAT || direction == State.FLAT) revert BadState();
        _accrueFees();
        (address lt, address st) = _legs(direction);
        uint256 nav = totalAssets();
        uint256 notional = _entryNotional(st);
        if (notional < MIN_NOTIONAL) revert NotionalTooSmall(notional);
        uint256 t = _ltvTarget(st, config.targetLtvBps);
        uint256 margin = Math.mulDiv(notional, WAD - t, t);

        // effects
        state = direction;
        entryTime = uint64(block.timestamp);
        entryZ = z;
        entryNav = nav;
        netFlowsSinceEntry = 0;

        // interactions
        IERC20 usdg = IERC20(asset());
        uint16 slip = config.maxSlippageBps;
        usdg.safeTransfer(address(longAdapter), notional);
        longAdapter.increase(lt, notional, slip, deadline);
        usdg.safeTransfer(address(shortAdapter), margin);
        shortAdapter.increase(st, notional, margin, slip, deadline);

        (uint256 l, uint256 s) = _checkInvariants(lt, st);
        emit Entered(direction, z, l, s, margin, nav);
    }
    // slither-disable-end unused-return

    function exit(uint8 reason, int256 z, uint256 deadline) external onlyEngine nonReentrant {
        if (state == State.FLAT) revert BadState();
        _accrueFees();
        _closeAll(config.maxSlippageBps, deadline);
        _markFlat(reason, z);
    }

    /// @notice Guardian escape hatch: closes both legs regardless of market hours or pause state.
    ///         Swaps remain bounded by the oracle and `slippageBps` (<= 5%).
    function emergencyExit(uint16 slippageBps, uint256 deadline) external onlyRole(GUARDIAN_ROLE) nonReentrant {
        if (state == State.FLAT) revert BadState();
        if (slippageBps > MAX_EMERGENCY_SLIPPAGE_BPS) revert BadConfig();
        _closeAll(slippageBps, deadline);
        _markFlat(EXIT_EMERGENCY, 0);
    }

    function rebalance(uint256 deadline) external onlyEngine nonReentrant whenNotPaused {
        if (state == State.FLAT) revert BadState();
        _accrueFees();
        (address lt, address st) = _legs(state);
        _rebalanceLtv(lt, st, deadline);
        _rebalanceHedge(lt, st, deadline);
        (uint256 l, uint256 s) = _checkInvariants(lt, st);
        emit Rebalanced(l, s, shortAdapter.ltv(st));
    }

    /// @dev Short-leg LTV: top up collateral from the reserve if it suffices, otherwise cut both legs by the same
    ///      fraction f, repaying debt without releasing collateral so that debt * (1 - f) / coll == target.
    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function _rebalanceLtv(address lt, address st, uint256 deadline) internal {
        uint256 lltv_ = shortAdapter.lltv(st);
        if (shortAdapter.ltv(st) <= Math.mulDiv(lltv_, config.rebalanceLtvBps, BPS)) return;
        uint256 wanted = Math.mulDiv(shortAdapter.debtValue(st), WAD, Math.mulDiv(lltv_, config.targetLtvBps, BPS));
        uint256 coll = shortAdapter.collateralValue(st);
        if (wanted <= coll) return;
        IERC20 usdg = IERC20(asset());
        if (usdg.balanceOf(address(this)) >= wanted - coll) {
            usdg.safeTransfer(address(shortAdapter), wanted - coll);
            shortAdapter.addCollateral(st, wanted - coll);
        } else {
            uint256 f = WAD - Math.mulDiv(coll, WAD, wanted);
            uint16 slip = config.maxSlippageBps;
            longAdapter.decrease(lt, f, slip, deadline);
            usdg.safeTransfer(address(shortAdapter), usdg.balanceOf(address(this)));
            shortAdapter.deleverage(st, f, slip, deadline);
        }
    }
    // slither-disable-end unused-return

    /// @dev Hedge: bring $B / $A back to the (tilt-clamped) weekly hedge ratio by trimming the over-sized leg.
    function _rebalanceHedge(address lt, address st, uint256 deadline) internal {
        (uint256 nA, uint256 nB, uint256 h) = _hedgeState(lt, st);
        uint256 tol = config.rebalanceTriggerBps / 2;
        uint256 targetB = Math.mulDiv(nA, h, WAD);
        if (nB * BPS > targetB * (BPS + tol)) {
            _trimLeg(tokenB, Math.mulDiv(nB - targetB, WAD, nB), lt, st, deadline);
        } else if (nB * BPS < targetB * (BPS - tol)) {
            uint256 targetA = Math.mulDiv(nB, WAD, h);
            _trimLeg(tokenA, Math.mulDiv(nA - targetA, WAD, nA), lt, st, deadline);
        }
    }

    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function _trimLeg(address leg, uint256 f, address lt, address st, uint256 deadline) internal {
        if (f == 0) return;
        uint16 slip = config.maxSlippageBps;
        if (leg == lt) {
            longAdapter.decrease(lt, f, slip, deadline);
        } else {
            IERC20 usdg = IERC20(asset());
            usdg.safeTransfer(address(shortAdapter), usdg.balanceOf(address(this)));
            shortAdapter.decrease(st, f, slip, deadline);
        }
    }
    // slither-disable-end unused-return

    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start unused-return
    function _closeAll(uint256 slip, uint256 deadline) internal {
        (address lt, address st) = _legs(state);
        longAdapter.decrease(lt, WAD, slip, deadline);
        IERC20 usdg = IERC20(asset());
        uint256 bal = usdg.balanceOf(address(this));
        if (bal != 0) usdg.safeTransfer(address(shortAdapter), bal);
        shortAdapter.decrease(st, WAD, slip, deadline);
    }
    // slither-disable-end unused-return

    function _markFlat(uint8 reason, int256 z) internal {
        uint256 navAfter = IERC20(asset()).balanceOf(address(this));
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 pnl = int256(navAfter) - int256(entryNav) - netFlowsSinceEntry;
        state = State.FLAT;
        entryTime = 0;
        emit Exited(reason, z, navAfter, pnl);
    }

    // ================================================================ ERC-4626

    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (state == State.FLAT) return idle;
        (address lt, address st) = _legs(state);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 total = int256(idle + longAdapter.value(lt)) + shortAdapter.equity(st);
        // forge-lint: disable-next-line(unsafe-typecast)
        return total > 0 ? uint256(total) : 0;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        _beforeDeposit(receiver);
        uint256 shares = super.deposit(assets, receiver);
        _trackFlow(int256(assets));
        return shares;
    }

    function mint(uint256 shares, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        _beforeDeposit(receiver);
        uint256 assets = super.mint(shares, receiver);
        _trackFlow(int256(assets));
        return assets;
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        return _redeemFlow(shares, receiver, owner, 0);
    }

    /// @notice Redeem with an explicit minimum (recommended for in-position exits).
    function redeem(uint256 shares, address receiver, address owner, uint256 minAssets)
        external
        nonReentrant
        returns (uint256)
    {
        return _redeemFlow(shares, receiver, owner, minAssets);
    }

    // slither: reentrancy-balance: balance-delta is the *measurement* of delivery; function is nonReentrant and the callee is a trusted, immutable protocol contract
    // slither-disable-start reentrancy-balance
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _accrueFees();
        shares = previewWithdraw(assets);
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) revert ERC4626ExceededMaxWithdraw(owner, assets, maxWithdraw(owner));
        if (state != State.FLAT) {
            uint256 realized = _unwindProRata(shares);
            if (realized < assets) revert SlippageExceeded(realized, assets);
            // any surplus stays in the vault for remaining holders
        }
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        // forge-lint: disable-next-line(unsafe-typecast)
        _trackFlow(-int256(assets));
    }
    // slither-disable-end reentrancy-balance

    function _redeemFlow(uint256 shares, address receiver, address owner, uint256 minAssets)
        internal
        returns (uint256 assets)
    {
        _accrueFees();
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        bool wasFullExit = state != State.FLAT && shares == totalSupply();
        assets = state == State.FLAT ? previewRedeem(shares) : _unwindProRata(shares);
        if (assets < minAssets) revert SlippageExceeded(assets, minAssets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        // forge-lint: disable-next-line(unsafe-typecast)
        _trackFlow(-int256(assets));
        if (wasFullExit) _markFlat(EXIT_FULL_REDEMPTION, 0);
    }

    /// @dev Sells `shares / totalSupply` of every leg and of idle cash. Returns realized USDG for the redeemer.
    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither: incorrect-equality: exact-zero checks are early returns on empty positions/supply, not equality on attacker-controlled balances
    // slither-disable-start unused-return
    // slither-disable-start incorrect-equality
    function _unwindProRata(uint256 shares) internal returns (uint256 payout) {
        if (paused()) revert EnforcedPause();
        if (!clock.isMarketOpen()) revert MarketClosed();
        uint256 supply = totalSupply();
        uint256 f = Math.mulDiv(shares, WAD, supply);
        if (f == 0) return 0;
        IERC20 usdg = IERC20(asset());
        uint256 idle = usdg.balanceOf(address(this));
        uint256 keep = idle - Math.mulDiv(idle, f, WAD);
        (address lt, address st) = _legs(state);
        uint16 slip = config.maxSlippageBps;

        longAdapter.decrease(lt, f, slip, block.timestamp);
        uint256 fund = usdg.balanceOf(address(this)) - keep;
        if (fund != 0) usdg.safeTransfer(address(shortAdapter), fund);
        shortAdapter.decrease(st, f, slip, block.timestamp);
        payout = usdg.balanceOf(address(this)) - keep;
    }
    // slither-disable-end unused-return
    // slither-disable-end incorrect-equality

    function previewRedeem(uint256 shares) public view override returns (uint256 assets) {
        assets = _convertToAssets(shares, Math.Rounding.Floor);
        if (state != State.FLAT) assets = Math.mulDiv(assets, BPS - 2 * uint256(config.maxSlippageBps), BPS);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        if (state != State.FLAT) {
            assets = Math.mulDiv(assets, BPS, BPS - 2 * uint256(config.maxSlippageBps), Math.Rounding.Ceil);
        }
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused() || !_allowed(receiver)) return 0;
        if (state != State.FLAT && !clock.isMarketOpen()) return 0;
        uint256 cap = config.depositCap;
        if (cap == 0) return type(uint256).max;
        uint256 ta = totalAssets();
        return ta >= cap ? 0 : cap - ta;
    }

    // slither: incorrect-equality: exact-zero checks are early returns on empty positions/supply, not equality on attacker-controlled balances
    // slither-disable-start incorrect-equality
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return maxAssets == type(uint256).max ? type(uint256).max : _convertToShares(maxAssets, Math.Rounding.Floor);
    }
    // slither-disable-end incorrect-equality

    function maxRedeem(address owner) public view override returns (uint256) {
        if (state != State.FLAT && (paused() || !clock.isMarketOpen())) return 0;
        return balanceOf(owner);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return previewRedeem(maxRedeem(owner));
    }

    /// @dev Conversions include not-yet-minted fee shares so previews match execution.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 ta, uint256 ts) = _effectiveTotals();
        return Math.mulDiv(assets, ts + 10 ** _decimalsOffset(), ta + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 ta, uint256 ts) = _effectiveTotals();
        return Math.mulDiv(shares, ta + 1, ts + 10 ** _decimalsOffset(), rounding);
    }

    function _effectiveTotals() internal view returns (uint256 ta, uint256 ts) {
        ta = totalAssets();
        ts = totalSupply();
        (uint256 m, uint256 p,) = _pendingFees(ta, ts);
        ts += m + p;
    }

    /// @dev Share transfers to non-allowlisted accounts are blocked while compliance is enabled.
    ///      Mints/burns (deposit/withdraw paths) are gated elsewhere; withdrawals are never gated.
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
        if (from != address(0) && to != address(0) && !_allowed(to)) revert NotAllowed(to);
        super._update(from, to, value);
    }

    function decimals() public view override(ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }

    // ================================================================ fees

    function accrueFees() external nonReentrant {
        _accrueFees();
    }

    function _accrueFees() internal {
        (uint256 m, uint256 p) = _accrueFeesState();
        _notifyFees(feeCollector, m, p);
    }

    /// @dev Effects only: mints fee shares and moves the accrual clock / high-water mark.
    function _accrueFeesState() internal returns (uint256 m, uint256 p) {
        uint256 ts = totalSupply();
        if (ts == 0) {
            lastFeeAccrual = uint64(block.timestamp);
            highWaterMark = _pps(totalAssets(), 0);
            return (0, 0);
        }
        uint256 hwm;
        (m, p, hwm) = _pendingFees(totalAssets(), ts);
        lastFeeAccrual = uint64(block.timestamp);
        highWaterMark = hwm;
        if (m + p != 0) {
            _mint(feeCollector, m + p);
            emit FeesAccrued(m, p, hwm);
        }
    }

    /// @dev Interaction only: tells the collector how the minted shares split.
    function _notifyFees(address fc, uint256 m, uint256 p) internal {
        if (m + p != 0) IFeeCollector(fc).onFeesMinted(m, p);
    }

    // slither: incorrect-equality: exact-zero checks are early returns on empty positions/supply, not equality on attacker-controlled balances
    // slither-disable-start incorrect-equality
    function _pendingFees(uint256 ta, uint256 ts) internal view returns (uint256 m, uint256 p, uint256 hwm) {
        hwm = highWaterMark;
        if (ts == 0 || feeCollector == address(0) || ta == 0) return (0, 0, hwm);
        uint256 elapsed = block.timestamp - lastFeeAccrual;
        uint256 mgmtAssets = Math.mulDiv(ta, uint256(managementFeeBps) * elapsed, BPS * YEAR);
        if (mgmtAssets != 0 && mgmtAssets < ta) m = Math.mulDiv(mgmtAssets, ts, ta - mgmtAssets);
        uint256 s1 = ts + m;
        uint256 pps = _pps(ta, s1);
        if (pps > hwm && hwm != 0 && performanceFeeBps != 0) {
            uint256 gain = Math.mulDiv(pps - hwm, s1 + 10 ** _decimalsOffset(), WAD);
            uint256 perfAssets = Math.mulDiv(gain, performanceFeeBps, BPS);
            if (perfAssets != 0 && perfAssets < ta) p = Math.mulDiv(perfAssets, s1, ta - perfAssets);
            hwm = _pps(ta, s1 + p);
        } else if (hwm == 0) {
            hwm = pps;
        }
    }
    // slither-disable-end incorrect-equality

    function _pps(uint256 ta, uint256 ts) internal pure returns (uint256) {
        return Math.mulDiv(ta + 1, WAD, ts + 10 ** 6);
    }

    // ================================================================ views

    function shortToken() external view returns (address) {
        if (state == State.FLAT) return address(0);
        (, address st) = _legs(state);
        return st;
    }

    function longToken() external view returns (address) {
        if (state == State.FLAT) return address(0);
        (address lt,) = _legs(state);
        return lt;
    }

    function pricePerShare() external view returns (uint256) {
        return _convertToAssets(10 ** decimals(), Math.Rounding.Floor);
    }

    /// @notice Max per-leg notional the vault would open in `direction` right now.
    function capacityUsdg(State direction) external view returns (uint256) {
        if (direction == State.FLAT) return 0;
        (, address st) = _legs(direction);
        return _entryNotional(st);
    }

    function needsRebalance() external view returns (bool) {
        if (state == State.FLAT) return false;
        (address lt, address st) = _legs(state);
        if (shortAdapter.ltv(st) > Math.mulDiv(shortAdapter.lltv(st), config.rebalanceLtvBps, BPS)) return true;
        (uint256 nA, uint256 nB, uint256 h) = _hedgeState(lt, st);
        uint256 targetB = Math.mulDiv(nA, h, WAD);
        if (targetB == 0) return false;
        uint256 diff = nB > targetB ? nB - targetB : targetB - nB;
        return diff * BPS > targetB * config.rebalanceTriggerBps;
    }

    /// @notice (long value, short debt value, short LTV, LTV cap) for monitoring.
    function legs() external view returns (uint256 longValue, uint256 shortValue, uint256 ltv, uint256 maxLtv) {
        if (state == State.FLAT) return (0, 0, 0, 0);
        (address lt, address st) = _legs(state);
        longValue = longAdapter.value(lt);
        shortValue = shortAdapter.debtValue(st);
        ltv = shortAdapter.ltv(st);
        maxLtv = Math.mulDiv(shortAdapter.lltv(st), config.maxLtvBps, BPS);
    }

    // ================================================================ internals

    function _legs(State s) internal view returns (address lt, address st) {
        (lt, st) = s == State.LONG_SPREAD ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _ltvTarget(address st, uint16 bps) internal view returns (uint256) {
        return Math.mulDiv(shortAdapter.lltv(st), bps, BPS);
    }

    function _entryNotional(address st) internal view returns (uint256 n) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 t = _ltvTarget(st, config.targetLtvBps);
        // capital per $1 notional = 1 (long) + (1 - t) / t (short margin) = 1 / t
        n = Math.mulDiv(Math.mulDiv(idle, config.deployBps, BPS), t, WAD);
        uint256 cap = Math.mulDiv(shortAdapter.capacityUsdg(st), 9_000, BPS);
        if (n > cap) n = cap;
        if (config.maxNotionalUsdg != 0 && n > config.maxNotionalUsdg) n = config.maxNotionalUsdg;
    }

    function _hedgeState(address lt, address st) internal view returns (uint256 nA, uint256 nB, uint256 h) {
        uint256 l = longAdapter.value(lt);
        uint256 s = shortAdapter.debtValue(st);
        (nA, nB) = lt == tokenA ? (l, s) : (s, l);
        h = spreadOracle.hedgeRatio(pairId);
        uint256 lo = WAD - Math.mulDiv(WAD, config.maxTiltBps, BPS);
        uint256 hi = WAD + Math.mulDiv(WAD, config.maxTiltBps, BPS);
        h = h < lo ? lo : (h > hi ? hi : h);
    }

    function _checkInvariants(address lt, address st) internal view returns (uint256 l, uint256 s) {
        l = longAdapter.value(lt);
        s = shortAdapter.debtValue(st);
        uint256 hi = l > s ? l : s;
        uint256 diff = l > s ? l - s : s - l;
        if (diff * BPS > hi * config.bandBps) revert BandBreached(l, s);
        uint256 maxLtv = Math.mulDiv(shortAdapter.lltv(st), config.maxLtvBps, BPS);
        uint256 cur = shortAdapter.ltv(st);
        if (cur > maxLtv) revert LtvTooHigh(cur, maxLtv);
    }

    function _beforeDeposit(address receiver) internal {
        if (!_allowed(_msgSender())) revert NotAllowed(_msgSender());
        if (!_allowed(receiver)) revert NotAllowed(receiver);
        if (state != State.FLAT && !clock.isMarketOpen()) revert MarketClosed();
        _accrueFees();
    }

    function _trackFlow(int256 delta) internal {
        if (state != State.FLAT) netFlowsSinceEntry += delta;
    }

    function _allowed(address account) internal view returns (bool) {
        IComplianceRegistry c = compliance;
        return address(c) == address(0) || c.isAllowed(account);
    }
}
