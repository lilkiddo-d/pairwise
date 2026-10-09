// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, Id} from "./interfaces/external/IMorpho.sol";
import {ISwapVenue} from "./interfaces/ISwapVenue.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";
import {ILongAdapter, IShortAdapter} from "./interfaces/IAdapters.sol";
import {ISpreadOracle, IStrategyEngine, IFeeCollector} from "./interfaces/IPairwise.sol";
import {PairVault} from "./PairVault.sol";
import {LongAdapter} from "./LongAdapter.sol";
import {ShortAdapter} from "./ShortAdapter.sol";

/// @title PairVaultFactory
/// @notice Lists new pairs. Each listing deploys three immutable EIP-1167 clones (vault, long adapter, short
///         adapter), registers the pair's ring buffer in SpreadOracle and the vault in StrategyEngine/FeeCollector.
///         LISTER_ROLE is held by the Timelock: every listing (including $PAIR-staker proposals) is 48h-delayed.
contract PairVaultFactory is AccessControl, ReentrancyGuard {
    bytes32 public constant LISTER_ROLE = keccak256("LISTER_ROLE");

    struct Shared {
        IERC20 usdg;
        IMorpho morpho;
        ISwapVenue venue;
        IPriceOracle oracle;
        ISpreadOracle spreadOracle;
        IMarketClock clock;
        address engine;
        address feeCollector;
        address compliance;
        address vaultAdmin;
        address guardian;
    }

    struct VaultSpec {
        address tokenA;
        address tokenB;
        bytes32 marketIdA;
        bytes32 marketIdB;
        uint16 window;
        string name;
        string symbol;
    }

    struct VaultRecord {
        address vault;
        address longAdapter;
        address shortAdapter;
        uint256 pairId;
        address tokenA;
        address tokenB;
    }

    address public immutable vaultImpl;
    address public immutable longImpl;
    address public immutable shortImpl;

    Shared internal _shared;
    PairVault.Config internal _defaultConfig;
    uint16 public defaultManagementFeeBps;
    uint16 public defaultPerformanceFeeBps;

    VaultRecord[] internal _vaults;
    mapping(address tokenA => mapping(address tokenB => address vault)) public vaultFor;

    event VaultCreated(
        address indexed vault,
        uint256 indexed pairId,
        address tokenA,
        address tokenB,
        address longAdapter,
        address shortAdapter
    );
    event SharedSet(Shared shared);
    event DefaultsSet(PairVault.Config config, uint16 managementFeeBps, uint16 performanceFeeBps);

    error PairExists();
    error BadParam();

    constructor(
        address admin,
        address vaultImpl_,
        address longImpl_,
        address shortImpl_,
        Shared memory shared_,
        PairVault.Config memory config_,
        uint16 mgmtBps,
        uint16 perfBps
    ) {
        if (vaultImpl_ == address(0) || longImpl_ == address(0) || shortImpl_ == address(0)) revert BadParam();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        vaultImpl = vaultImpl_;
        longImpl = longImpl_;
        shortImpl = shortImpl_;
        _setShared(shared_);
        _setDefaults(config_, mgmtBps, perfBps);
    }

    function setShared(Shared calldata s) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setShared(s);
    }

    function setDefaults(PairVault.Config calldata c, uint16 mgmtBps, uint16 perfBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setDefaults(c, mgmtBps, perfBps);
    }

    function _setShared(Shared memory s) internal {
        if (
            address(s.usdg) == address(0) || address(s.morpho) == address(0) || address(s.venue) == address(0)
                || address(s.oracle) == address(0) || address(s.spreadOracle) == address(0)
                || address(s.clock) == address(0) || s.engine == address(0) || s.vaultAdmin == address(0)
                || s.guardian == address(0)
        ) revert BadParam();
        _shared = s;
        emit SharedSet(s);
    }

    function _setDefaults(PairVault.Config memory c, uint16 mgmtBps, uint16 perfBps) internal {
        if (mgmtBps > 100 || perfBps > 1_500) revert BadParam(); // mirrors PairVault hard caps
        _defaultConfig = c;
        defaultManagementFeeBps = mgmtBps;
        defaultPerformanceFeeBps = perfBps;
        emit DefaultsSet(c, mgmtBps, perfBps);
    }

    function createVault(VaultSpec calldata spec)
        external
        onlyRole(LISTER_ROLE)
        nonReentrant
        returns (address vault, address longAdapter, address shortAdapter)
    {
        if (vaultFor[spec.tokenA][spec.tokenB] != address(0) || vaultFor[spec.tokenB][spec.tokenA] != address(0)) {
            revert PairExists();
        }
        Shared memory s = _shared;
        vault = Clones.clone(vaultImpl);
        longAdapter = Clones.clone(longImpl);
        shortAdapter = Clones.clone(shortImpl);
        vaultFor[spec.tokenA][spec.tokenB] = vault; // effect before any external call

        uint256 pairId = s.spreadOracle.registerPair(spec.tokenA, spec.tokenB, spec.window);

        LongAdapter(longAdapter).initialize(vault, s.usdg, s.venue, s.oracle, spec.tokenA, spec.tokenB);
        _initShort(shortAdapter, vault, spec);
        _initVault(vault, longAdapter, shortAdapter, pairId, spec);

        IStrategyEngine(s.engine).registerVault(vault);
        if (s.feeCollector != address(0)) IFeeCollector(s.feeCollector).registerVault(vault);

        _vaults.push(VaultRecord(vault, longAdapter, shortAdapter, pairId, spec.tokenA, spec.tokenB));
        emit VaultCreated(vault, pairId, spec.tokenA, spec.tokenB, longAdapter, shortAdapter);
    }

    function _initShort(address shortAdapter, address vault, VaultSpec calldata spec) internal {
        Shared storage s = _shared;
        ShortAdapter(shortAdapter)
            .initialize(
                vault,
                s.morpho,
                s.usdg,
                s.venue,
                s.oracle,
                spec.tokenA,
                Id.wrap(spec.marketIdA),
                spec.tokenB,
                Id.wrap(spec.marketIdB)
            );
    }

    function _initVault(
        address vault,
        address longAdapter,
        address shortAdapter,
        uint256 pairId,
        VaultSpec calldata spec
    ) internal {
        Shared storage s = _shared;
        // slither-disable-next-line uninitialized-local
        PairVault.InitParams memory p;
        p.usdg = s.usdg;
        p.name = spec.name;
        p.symbol = spec.symbol;
        p.pairId = pairId;
        p.tokenA = spec.tokenA;
        p.tokenB = spec.tokenB;
        p.longAdapter = ILongAdapter(longAdapter);
        p.shortAdapter = IShortAdapter(shortAdapter);
        p.oracle = s.oracle;
        p.spreadOracle = s.spreadOracle;
        p.clock = s.clock;
        p.engine = s.engine;
        p.feeCollector = s.feeCollector;
        p.compliance = s.compliance;
        p.admin = s.vaultAdmin;
        p.guardian = s.guardian;
        p.config = _defaultConfig;
        p.managementFeeBps = defaultManagementFeeBps;
        p.performanceFeeBps = defaultPerformanceFeeBps;
        PairVault(vault).initialize(p);
    }

    // ---------------------------------------------------------------- views

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function vaultAt(uint256 i) external view returns (VaultRecord memory) {
        return _vaults[i];
    }

    function allVaults() external view returns (VaultRecord[] memory) {
        return _vaults;
    }

    function shared() external view returns (Shared memory) {
        return _shared;
    }

    function defaultConfig() external view returns (PairVault.Config memory) {
        return _defaultConfig;
    }
}
