// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PairwiseTimelock} from "../src/PairwiseTimelock.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {SpreadOracle} from "../src/SpreadOracle.sol";
import {UniswapV3SwapVenue} from "../src/UniswapV3SwapVenue.sol";
import {LongAdapter} from "../src/LongAdapter.sol";
import {ShortAdapter} from "../src/ShortAdapter.sol";
import {PairVault} from "../src/PairVault.sol";
import {StrategyEngine} from "../src/StrategyEngine.sol";
import {PairVaultFactory} from "../src/PairVaultFactory.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {IMorpho} from "../src/interfaces/external/IMorpho.sol";
import {ISwapRouter02} from "../src/interfaces/external/ISwapRouter02.sol";
import {ISpreadOracle} from "../src/interfaces/IPairwise.sol";
import {IMarketClock} from "../src/interfaces/IMarketClock.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ISwapVenue} from "../src/interfaces/ISwapVenue.sol";

/// @title Deploy
/// @notice One-shot deployment of the whole Pairwise protocol on Robinhood Chain:
///         deploys + wires every contract, lists the launch pairs, hands every admin role to the 48h Timelock,
///         renounces all deployer privileges, and (on broadcast) writes deployments/<chainId>.json and the
///         frontend config app/public/deployments/<chainId>.json.
///
///         Signing: only via the Foundry keystore account `pairwise-deployer` (`--account pairwise-deployer`).
///         The script never reads or handles private keys.
///
///         Optional env:
///           KEEPER_ADDRESS     keeper EOA (address of the `pairwise-keeper` keystore). Default: deployer.
///           GUARDIAN_ADDRESS   pause/emergency multisig. Default: deployer.
///           TIMELOCK_ADMIN     Timelock proposer+executor (use a Safe). Default: deployer.
///           PAIRWISE_CONFIG    chain config JSON. Default: ../config/robinhood-mainnet.json
contract Deploy is Script {
    uint256 internal constant TIMELOCK_DELAY = 48 hours;
    uint32 internal constant STOCK_MAX_STALENESS = 26 hours; // Chainlink heartbeat 24h + buffer
    uint256 internal constant PROPOSAL_THRESHOLD = 10_000e18; // $PAIR needed to propose a pair (when token is set)

    struct Roles {
        address deployer;
        address keeper;
        address guardian;
        address timelockAdmin;
    }

    struct Deployment {
        address timelock;
        address clock;
        address oracle;
        address spreadOracle;
        address swapVenue;
        address engine;
        address feeCollector;
        address hooks;
        address compliance;
        address factory;
        address vaultImpl;
        address longImpl;
        address shortImpl;
        address[] vaults;
    }

    string internal json;

    function run() external returns (Deployment memory d) {
        json = vm.readFile(vm.envOr("PAIRWISE_CONFIG", string("../config/robinhood-mainnet.json")));
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Roles memory r = Roles({
            deployer: deployer,
            keeper: vm.envOr("KEEPER_ADDRESS", deployer),
            guardian: vm.envOr("GUARDIAN_ADDRESS", deployer),
            timelockAdmin: vm.envOr("TIMELOCK_ADMIN", deployer)
        });
        d = deploy(r);
        vm.stopBroadcast();

        verifyHandover(d, r);
        _log(d, r);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            _write(d, r);
        } else {
            console2.log("Dry run: deployment files not written.");
        }
    }

    /// @dev Pure wiring; callable from tests with an already-loaded config.
    function deployWithConfig(string memory configJson, Roles memory r) public returns (Deployment memory d) {
        json = configJson;
        d = deploy(r);
        verifyHandover(d, r);
    }

    Deployment internal dep;

    function deploy(Roles memory r) internal returns (Deployment memory) {
        delete dep;
        _deployInfra(r);
        _deployCore(r);
        _deployFactory(r);
        _wireRoles(r);
        _listPairs();
        _handoverAll(r);
        return dep;
    }

    function _deployInfra(Roles memory r) internal {
        address usdg = _token("USDG");
        address[] memory admins = new address[](1);
        admins[0] = r.timelockAdmin;
        dep.timelock = address(new PairwiseTimelock(TIMELOCK_DELAY, admins, admins));

        MarketClock clock = new MarketClock(r.deployer, r.deployer);
        clock.setHolidays(vm.parseJsonUintArray(json, ".holidays.closed"), true);
        clock.setEarlyCloses(vm.parseJsonUintArray(json, ".holidays.earlyClose"), true);
        dep.clock = address(clock);

        OracleAdapter oracle = new OracleAdapter(r.deployer);
        oracle.setFeed(usdg, vm.parseJsonAddress(json, ".chainlink.USDG.feed"), STOCK_MAX_STALENESS, address(0), 0);
        address seq = vm.parseJsonAddress(json, ".chainlink.sequencerUptimeFeed");
        if (seq != address(0)) oracle.setSequencerUptimeFeed(seq);
        dep.oracle = address(oracle);

        dep.swapVenue = address(
            new UniswapV3SwapVenue(r.deployer, ISwapRouter02(vm.parseJsonAddress(json, ".uniswapV3.swapRouter02")))
        );
        string[] memory stocks = vm.parseJsonKeys(json, ".stocks");
        for (uint256 i; i < stocks.length; ++i) {
            _configureStock(stocks[i]);
        }
    }

    function _configureStock(string memory sym) internal {
        string memory base = string.concat(".stocks.", sym);
        OracleAdapter(dep.oracle).setFeed(
            vm.parseJsonAddress(json, string.concat(base, ".address")),
            vm.parseJsonAddress(json, string.concat(base, ".feed")),
            STOCK_MAX_STALENESS,
            address(0),
            0
        );
        string[] memory hops = vm.parseJsonStringArray(json, string.concat(base, ".route.tokens"));
        uint256[] memory feesRaw = vm.parseJsonUintArray(json, string.concat(base, ".route.fees"));
        address[] memory path = new address[](hops.length);
        uint24[] memory fees = new uint24[](feesRaw.length);
        for (uint256 j; j < hops.length; ++j) {
            path[j] = _token(hops[j]);
        }
        for (uint256 j; j < feesRaw.length; ++j) {
            fees[j] = uint24(feesRaw[j]);
        }
        UniswapV3SwapVenue(dep.swapVenue).setRoute(path, fees);
    }

    function _deployCore(Roles memory r) internal {
        address usdg = _token("USDG");
        dep.spreadOracle = address(new SpreadOracle(r.deployer, IPriceOracle(dep.oracle), IMarketClock(dep.clock)));
        dep.engine = address(
            new StrategyEngine(r.deployer, ISpreadOracle(dep.spreadOracle), IMarketClock(dep.clock), defaultParams())
        );
        dep.feeCollector = address(new FeeCollector(r.deployer, IERC20(usdg), 5_000));
        dep.hooks = address(new ProjectTokenHooks(r.deployer, IERC20(usdg), r.guardian, PROPOSAL_THRESHOLD));
        dep.compliance = address(new ComplianceRegistry(r.deployer, r.guardian)); // disabled by default
        dep.vaultImpl = address(new PairVault());
        dep.longImpl = address(new LongAdapter());
        dep.shortImpl = address(new ShortAdapter());
    }

    function _deployFactory(Roles memory r) internal {
        PairVaultFactory.Shared memory s = PairVaultFactory.Shared({
            usdg: IERC20(_token("USDG")),
            morpho: IMorpho(vm.parseJsonAddress(json, ".morpho.blue")),
            venue: ISwapVenue(dep.swapVenue),
            oracle: IPriceOracle(dep.oracle),
            spreadOracle: ISpreadOracle(dep.spreadOracle),
            clock: IMarketClock(dep.clock),
            engine: dep.engine,
            feeCollector: dep.feeCollector,
            compliance: dep.compliance,
            vaultAdmin: dep.timelock,
            guardian: r.guardian
        });
        dep.factory = address(
            new PairVaultFactory(
                r.deployer,
                dep.vaultImpl,
                dep.longImpl,
                dep.shortImpl,
                s,
                defaultConfig(),
                100, // 1%/yr management
                1_500 // 15% performance over HWM
            )
        );
    }

    function _wireRoles(Roles memory r) internal {
        SpreadOracle spread = SpreadOracle(dep.spreadOracle);
        StrategyEngine engine = StrategyEngine(dep.engine);
        FeeCollector fc = FeeCollector(dep.feeCollector);
        ProjectTokenHooks hooks = ProjectTokenHooks(dep.hooks);
        PairVaultFactory factory = PairVaultFactory(dep.factory);
        spread.grantRole(spread.REGISTRAR_ROLE(), dep.factory);
        spread.grantRole(spread.SEEDER_ROLE(), r.keeper);
        engine.grantRole(engine.REGISTRAR_ROLE(), dep.factory);
        engine.grantRole(engine.KEEPER_ROLE(), r.keeper);
        engine.grantRole(engine.GUARDIAN_ROLE(), r.guardian);
        fc.grantRole(fc.REGISTRAR_ROLE(), dep.factory);
        fc.setHooks(dep.hooks);
        hooks.grantRole(hooks.FEE_NOTIFIER_ROLE(), dep.feeCollector);
        MarketClock(dep.clock).grantRole(keccak256("CALENDAR_ROLE"), r.guardian);
        factory.grantRole(factory.LISTER_ROLE(), r.deployer); // temporary, for the launch listings
        factory.grantRole(factory.LISTER_ROLE(), dep.timelock);
    }

    function _listPairs() internal {
        for (uint256 i; i < 32; ++i) {
            string memory pb = string.concat(".pairs[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, pb)) break;
            string memory a = vm.parseJsonString(json, string.concat(pb, ".a"));
            string memory b = vm.parseJsonString(json, string.concat(pb, ".b"));
            (address v,,) = PairVaultFactory(dep.factory).createVault(
                PairVaultFactory.VaultSpec({
                    tokenA: _token(a),
                    tokenB: _token(b),
                    marketIdA: vm.parseJsonBytes32(json, string.concat(".stocks.", a, ".morphoMarketId")),
                    marketIdB: vm.parseJsonBytes32(json, string.concat(".stocks.", b, ".morphoMarketId")),
                    window: 30,
                    name: string.concat("Pairwise ", a, "/", b),
                    symbol: string.concat("pw", a, b)
                })
            );
            dep.vaults.push(v);
        }
    }

    function _handoverAll(Roles memory r) internal {
        _handover(dep.clock, dep.timelock, r.deployer);
        if (r.guardian != r.deployer) MarketClock(dep.clock).renounceRole(keccak256("CALENDAR_ROLE"), r.deployer);
        _handover(dep.oracle, dep.timelock, r.deployer);
        _handover(dep.swapVenue, dep.timelock, r.deployer);
        _handover(dep.spreadOracle, dep.timelock, r.deployer);
        _handover(dep.engine, dep.timelock, r.deployer);
        _handover(dep.feeCollector, dep.timelock, r.deployer);
        _handover(dep.hooks, dep.timelock, r.deployer);
        _handover(dep.compliance, dep.timelock, r.deployer);
        PairVaultFactory(dep.factory).renounceRole(keccak256("LISTER_ROLE"), r.deployer);
        _handover(dep.factory, dep.timelock, r.deployer);
    }

    function _handover(address target, address timelock, address deployer) internal {
        IAccessControl(target).grantRole(bytes32(0), timelock);
        IAccessControl(target).renounceRole(bytes32(0), deployer);
    }

    /// @notice Post-conditions: the Timelock is the only admin; the deployer keeps nothing.
    function verifyHandover(Deployment memory d, Roles memory r) public view {
        address[9] memory acs =
            [d.clock, d.oracle, d.swapVenue, d.spreadOracle, d.engine, d.feeCollector, d.hooks, d.compliance, d.factory];
        for (uint256 i; i < acs.length; ++i) {
            require(IAccessControl(acs[i]).hasRole(bytes32(0), d.timelock), "timelock not admin");
            if (r.deployer != d.timelock) {
                require(!IAccessControl(acs[i]).hasRole(bytes32(0), r.deployer), "deployer still admin");
            }
        }
        require(!IAccessControl(d.factory).hasRole(keccak256("LISTER_ROLE"), r.deployer), "deployer still lister");
        require(!IAccessControl(d.clock).hasRole(keccak256("CALENDAR_ROLE"), r.deployer) || r.deployer == r.guardian, "calendar");
        for (uint256 i; i < d.vaults.length; ++i) {
            require(IAccessControl(d.vaults[i]).hasRole(bytes32(0), d.timelock), "vault admin");
            require(!IAccessControl(d.vaults[i]).hasRole(bytes32(0), r.deployer), "vault deployer admin");
        }
        require(PairwiseTimelock(payable(d.timelock)).getMinDelay() >= 48 hours, "delay");
        require(address(ProjectTokenHooks(d.hooks).projectToken()) == address(0), "token must be unset");
    }

    // ---------------------------------------------------------------- defaults

    function defaultConfig() public pure returns (PairVault.Config memory) {
        return PairVault.Config({
            maxSlippageBps: 50,
            deployBps: 9_000,
            targetLtvBps: 6_500,
            rebalanceLtvBps: 7_500,
            maxLtvBps: 8_000,
            bandBps: 1_000,
            rebalanceTriggerBps: 500,
            maxTiltBps: 500,
            maxNotionalUsdg: 250_000e6,
            depositCap: 1_000_000e6
        });
    }

    function defaultParams() public pure returns (StrategyEngine.Params memory) {
        return StrategyEngine.Params({
            entryZ: 2e18,
            exitZ: 0.5e18,
            stopZ: 3.5e18,
            maxHolding: 20 days,
            cooldown: 1 days,
            confirmDelay: 15 minutes,
            armWindow: 2 hours,
            minCorrelation: 0.5e18,
            exitCorrelation: 0.2e18,
            maxBorrowApr: 0.5e18
        });
    }

    // ---------------------------------------------------------------- io

    function _token(string memory sym) internal view returns (address) {
        if (vm.keyExistsJson(json, string.concat(".tokens.", sym))) {
            return vm.parseJsonAddress(json, string.concat(".tokens.", sym, ".address"));
        }
        return vm.parseJsonAddress(json, string.concat(".stocks.", sym, ".address"));
    }

    function _log(Deployment memory d, Roles memory r) internal pure {
        console2.log("deployer      ", r.deployer);
        console2.log("keeper        ", r.keeper);
        console2.log("guardian      ", r.guardian);
        console2.log("timelock      ", d.timelock);
        console2.log("factory       ", d.factory);
        console2.log("engine        ", d.engine);
        console2.log("spreadOracle  ", d.spreadOracle);
        console2.log("hooks ($PAIR) ", d.hooks);
        for (uint256 i; i < d.vaults.length; ++i) {
            console2.log("vault         ", d.vaults[i]);
        }
    }

    function _write(Deployment memory d, Roles memory r) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "deployedAtBlock", block.number);
        vm.serializeAddress(o, "deployer", r.deployer);
        vm.serializeAddress(o, "keeper", r.keeper);
        vm.serializeAddress(o, "guardian", r.guardian);
        vm.serializeAddress(o, "timelockAdmin", r.timelockAdmin);
        vm.serializeAddress(o, "timelock", d.timelock);
        vm.serializeAddress(o, "marketClock", d.clock);
        vm.serializeAddress(o, "oracleAdapter", d.oracle);
        vm.serializeAddress(o, "spreadOracle", d.spreadOracle);
        vm.serializeAddress(o, "swapVenue", d.swapVenue);
        vm.serializeAddress(o, "strategyEngine", d.engine);
        vm.serializeAddress(o, "feeCollector", d.feeCollector);
        vm.serializeAddress(o, "projectTokenHooks", d.hooks);
        vm.serializeAddress(o, "complianceRegistry", d.compliance);
        vm.serializeAddress(o, "factory", d.factory);
        vm.serializeAddress(o, "usdg", _token("USDG"));
        vm.serializeAddress(o, "pairVaultImpl", d.vaultImpl);
        vm.serializeAddress(o, "longAdapterImpl", d.longImpl);
        vm.serializeAddress(o, "shortAdapterImpl", d.shortImpl);
        string memory out = vm.serializeAddress(o, "vaults", d.vaults);
        string memory id = vm.toString(block.chainid);
        vm.writeJson(out, string.concat("../deployments/", id, ".json"));
        vm.writeJson(out, string.concat("../app/public/deployments/", id, ".json"));
        console2.log("Wrote deployments/%s.json and app/public/deployments/%s.json", id, id);
    }
}
