// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";
import {IShortAdapter} from "./interfaces/IAdapters.sol";
import {IPairVault, ISpreadOracle, IPausableLike, IStrategyEngine} from "./interfaces/IPairwise.sol";

interface IPairVaultView is IPairVault {
    function shortAdapter() external view returns (IShortAdapter);
}

/// @title StrategyEngine
/// @notice Deterministic z-score pairs strategy. Keepers only *trigger*; every decision is derived on-chain:
///         - entry when entryZ <= |z| < stopZ and return correlation >= minCorrelation, after an arm -> confirm delay
///           (the signal must persist for `confirmDelay`, defeating one-block oracle spikes / keeper games)
///         - exit on mean reversion (|z| <= exitZ on the right side), stop (|z| >= stopZ against us),
///           max holding period, correlation breakdown, or borrow cost above `maxBorrowApr`
///         - rebalance when the vault reports LTV or hedge drift
///         Nothing executes outside the US regular session (MarketClock).
contract StrategyEngine is AccessControl, Pausable, ReentrancyGuard, IStrategyEngine {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 internal constant WAD = 1e18;
    uint256 public constant MAX_DEADLINE_WINDOW = 1 hours;
    uint256 public constant MAX_BATCH = 16;
    uint256 public constant MIN_ENTRY_NOTIONAL = 10e6;

    uint8 public constant EXIT_MEAN_REVERSION = 1;
    uint8 public constant EXIT_STOP_LOSS = 2;
    uint8 public constant EXIT_MAX_HOLDING = 3;
    uint8 public constant EXIT_CORRELATION = 4;
    uint8 public constant EXIT_BORROW_COST = 5;

    enum Action {
        NONE,
        ARM,
        ENTER,
        EXIT,
        REBALANCE
    }

    struct Params {
        uint256 entryZ; // 1e18-scaled, e.g. 2.0e18
        uint256 exitZ; // e.g. 0.5e18
        uint256 stopZ; // e.g. 3.5e18
        uint256 maxHolding; // seconds
        uint256 cooldown; // seconds after an exit before re-entry
        uint256 confirmDelay; // seconds a signal must persist after arming
        uint256 armWindow; // arm expires after this many seconds
        int256 minCorrelation; // entry gate, 1e18-scaled
        int256 exitCorrelation; // breakdown exit, 1e18-scaled
        uint256 maxBorrowApr; // 1e18-scaled annual rate; 0 disables
    }

    struct VaultInfo {
        bool registered;
        IPairVault.State armedDirection;
        uint64 armedAt;
        uint64 lastActionAt;
    }

    ISpreadOracle public immutable spreadOracle;
    IMarketClock public immutable clock;
    Params public defaultParams;
    mapping(address vault => Params) internal _params;
    mapping(address vault => VaultInfo) public vaultInfo;
    address[] public vaults;

    event VaultRegistered(address indexed vault);
    event ParamsSet(address indexed vault, Params params);
    event DefaultParamsSet(Params params);
    event Armed(address indexed vault, IPairVault.State direction, int256 z);
    event Executed(address indexed vault, Action indexed action, uint8 detail, int256 z, address keeper);

    error NotRegistered();
    error AlreadyRegistered();
    error BadParams();
    error BadDeadline();
    error NothingToDo();
    error BatchTooLarge();

    constructor(address admin, ISpreadOracle spreadOracle_, IMarketClock clock_, Params memory defaults) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        spreadOracle = spreadOracle_;
        clock = clock_;
        _validate(defaults);
        defaultParams = defaults;
        emit DefaultParamsSet(defaults);
    }

    // ---------------------------------------------------------------- admin

    function registerVault(address vault) external onlyRole(REGISTRAR_ROLE) {
        if (vaultInfo[vault].registered) revert AlreadyRegistered();
        vaultInfo[vault].registered = true;
        _params[vault] = defaultParams;
        vaults.push(vault);
        emit VaultRegistered(vault);
        emit ParamsSet(vault, defaultParams);
    }

    function setParams(address vault, Params calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!vaultInfo[vault].registered) revert NotRegistered();
        _validate(p);
        _params[vault] = p;
        emit ParamsSet(vault, p);
    }

    function setDefaultParams(Params calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validate(p);
        defaultParams = p;
        emit DefaultParamsSet(p);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _validate(Params memory p) internal pure {
        if (
            p.exitZ == 0 || p.exitZ >= p.entryZ || p.entryZ >= p.stopZ || p.stopZ > 10 * WAD
                || p.maxHolding < 1 days || p.maxHolding > 120 days || p.cooldown > 30 days
                || p.confirmDelay > 2 hours || p.armWindow <= p.confirmDelay || p.armWindow > 1 days
                || p.minCorrelation > int256(WAD) || p.minCorrelation < -int256(WAD)
                || p.exitCorrelation > p.minCorrelation || p.exitCorrelation < -int256(WAD)
        ) revert BadParams();
    }

    // ---------------------------------------------------------------- keeper

    function execute(address vault, uint256 deadline) public onlyRole(KEEPER_ROLE) whenNotPaused nonReentrant {
        if (deadline < block.timestamp || deadline > block.timestamp + MAX_DEADLINE_WINDOW) revert BadDeadline();
        (Action action, uint8 detail, int256 z) = check(vault);
        if (action == Action.NONE) revert NothingToDo();
        _apply(vault, action, detail, z, deadline);
    }

    /// @notice Executes every actionable vault in `list`, skipping those with nothing to do.
    function executeBatch(address[] calldata list, uint256 deadline)
        external
        onlyRole(KEEPER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 executed)
    {
        if (list.length > MAX_BATCH) revert BatchTooLarge();
        if (deadline < block.timestamp || deadline > block.timestamp + MAX_DEADLINE_WINDOW) revert BadDeadline();
        for (uint256 i; i < list.length; ++i) {
            (Action action, uint8 detail, int256 z) = check(list[i]);
            if (action == Action.NONE) continue;
            _apply(list[i], action, detail, z, deadline);
            ++executed;
        }
    }

    function _apply(address vault, Action action, uint8 detail, int256 z, uint256 deadline) internal {
        VaultInfo storage v = vaultInfo[vault];
        if (action == Action.ARM) {
            v.armedDirection = IPairVault.State(detail);
            v.armedAt = uint64(block.timestamp);
            emit Armed(vault, IPairVault.State(detail), z);
        } else if (action == Action.ENTER) {
            v.armedDirection = IPairVault.State.FLAT;
            v.armedAt = 0;
            v.lastActionAt = uint64(block.timestamp);
            IPairVault(vault).enter(IPairVault.State(detail), z, deadline);
        } else if (action == Action.EXIT) {
            v.lastActionAt = uint64(block.timestamp);
            IPairVault(vault).exit(detail, z, deadline);
        } else {
            IPairVault(vault).rebalance(deadline);
        }
        emit Executed(vault, action, detail, z, msg.sender);
    }

    // ---------------------------------------------------------------- views

    function params(address vault) external view returns (Params memory) {
        return _params[vault];
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    /// @notice What the keeper should do for `vault` right now, and why.
    /// @return action  the action
    /// @return detail  direction (ARM/ENTER) or exit reason (EXIT)
    /// @return z       current z-score used for the decision
    function check(address vault) public view returns (Action action, uint8 detail, int256 z) {
        VaultInfo storage v = vaultInfo[vault];
        if (!v.registered) revert NotRegistered();
        if (paused() || IPausableLike(vault).paused() || !clock.isMarketOpen()) return (Action.NONE, 0, 0);

        Params storage p = _params[vault];
        IPairVaultView pv = IPairVaultView(vault);
        uint256 pid = pv.pairId();
        bool ok;
        (z, ok) = spreadOracle.zScore(pid);
        (int256 corr, bool cok) = spreadOracle.correlation(pid);
        IPairVault.State st = pv.state();

        if (st == IPairVault.State.FLAT) {
            if (!ok || !cok || corr < p.minCorrelation) return (Action.NONE, 0, z);
            if (block.timestamp < uint256(v.lastActionAt) + p.cooldown) return (Action.NONE, 0, z);
            // never open a trade that is already beyond its own stop
            // forge-lint: disable-next-line(unsafe-typecast)
            if (z >= int256(p.stopZ) || z <= -int256(p.stopZ)) return (Action.NONE, 0, z);
            IPairVault.State dir;
            // forge-lint: disable-next-line(unsafe-typecast)
            if (z >= int256(p.entryZ)) dir = IPairVault.State.SHORT_SPREAD; // A rich vs B: short A, long B
            // forge-lint: disable-next-line(unsafe-typecast)
            else if (z <= -int256(p.entryZ)) dir = IPairVault.State.LONG_SPREAD; // A cheap vs B: long A, short B
            else return (Action.NONE, 0, z);
            if (pv.capacityUsdg(dir) < MIN_ENTRY_NOTIONAL) return (Action.NONE, 0, z);
            bool armedSame = v.armedDirection == dir && block.timestamp <= uint256(v.armedAt) + p.armWindow;
            if (!armedSame) return (Action.ARM, uint8(dir), z);
            if (block.timestamp < uint256(v.armedAt) + p.confirmDelay) return (Action.NONE, 0, z);
            return (Action.ENTER, uint8(dir), z);
        }

        if (ok) {
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 stopZ = int256(p.stopZ);
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 exitZ = int256(p.exitZ);
            if (st == IPairVault.State.LONG_SPREAD) {
                if (z <= -stopZ) return (Action.EXIT, EXIT_STOP_LOSS, z);
                if (z >= -exitZ) return (Action.EXIT, EXIT_MEAN_REVERSION, z);
            } else {
                if (z >= stopZ) return (Action.EXIT, EXIT_STOP_LOSS, z);
                if (z <= exitZ) return (Action.EXIT, EXIT_MEAN_REVERSION, z);
            }
        }
        if (block.timestamp >= uint256(pv.entryTime()) + p.maxHolding) return (Action.EXIT, EXIT_MAX_HOLDING, z);
        if (cok && corr < p.exitCorrelation) return (Action.EXIT, EXIT_CORRELATION, z);
        if (p.maxBorrowApr != 0) {
            uint256 apr = pv.shortAdapter().borrowRatePerSecond(pv.shortToken()) * 365 days;
            if (apr > p.maxBorrowApr) return (Action.EXIT, EXIT_BORROW_COST, z);
        }
        if (pv.needsRebalance()) return (Action.REBALANCE, 0, z);
        return (Action.NONE, 0, z);
    }
}
