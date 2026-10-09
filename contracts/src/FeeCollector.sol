// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFeeCollector, IProjectTokenHooks} from "./interfaces/IPairwise.sol";

/// @title FeeCollector
/// @notice Receives fee shares minted by vaults, converts them to USDG on `harvest`, and splits performance fees:
///         `stakerShareBps` goes to $PAIR stakers via ProjectTokenHooks (only once the project token is set and
///         someone is staking), the remainder accrues to the treasury, withdrawable only by the Timelock.
contract FeeCollector is AccessControl, ReentrancyGuard, IFeeCollector {
    using SafeERC20 for IERC20;

    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    uint256 public constant MAX_STAKER_SHARE_BPS = 5_000;

    IERC20 public immutable usdg;
    IProjectTokenHooks public hooks;
    uint16 public stakerShareBps;

    mapping(address vault => bool) public isVault;
    mapping(address vault => uint256) public pendingManagementShares;
    mapping(address vault => uint256) public pendingPerformanceShares;
    uint256 public treasuryBalance;

    event VaultRegistered(address indexed vault);
    event FeesRecorded(address indexed vault, uint256 managementShares, uint256 performanceShares);
    event Harvested(address indexed vault, uint256 assets, uint256 toStakers, uint256 toTreasury);
    event HooksSet(address hooks);
    event StakerShareSet(uint16 bps);
    event TreasuryWithdrawn(address indexed to, uint256 amount);

    error NotVault();
    error BadParam();
    error NothingToHarvest();
    error InsufficientTreasury();

    constructor(address admin, IERC20 usdg_, uint16 stakerShareBps_) {
        if (stakerShareBps_ > MAX_STAKER_SHARE_BPS) revert BadParam();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        usdg = usdg_;
        stakerShareBps = stakerShareBps_;
    }

    function registerVault(address vault) external onlyRole(REGISTRAR_ROLE) {
        isVault[vault] = true;
        emit VaultRegistered(vault);
    }

    function setHooks(address hooks_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = IProjectTokenHooks(hooks_);
        emit HooksSet(hooks_);
    }

    function setStakerShareBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_STAKER_SHARE_BPS) revert BadParam();
        stakerShareBps = bps;
        emit StakerShareSet(bps);
    }

    /// @inheritdoc IFeeCollector
    function onFeesMinted(uint256 managementShares, uint256 performanceShares) external {
        if (!isVault[msg.sender]) revert NotVault();
        pendingManagementShares[msg.sender] += managementShares;
        pendingPerformanceShares[msg.sender] += performanceShares;
        emit FeesRecorded(msg.sender, managementShares, performanceShares);
    }

    /// @notice Permissionless: redeems this collector's recorded fee shares of `vault` into USDG and splits them.
    ///         While the vault is in a position the redemption unwinds pro-rata (bounded by oracle slippage), so
    ///         `minAssets` protects the treasury against bad execution.
    // slither: reentrancy-balance: balance-delta is the *measurement* of delivery; function is nonReentrant and the callee is a trusted, immutable protocol contract
    // slither: unused-return: return values intentionally ignored: amounts are re-measured via balances/positions or are not needed
    // slither-disable-start reentrancy-balance
    // slither-disable-start unused-return
    function harvest(address vault, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        if (!isVault[vault]) revert NotVault();
        uint256 m = pendingManagementShares[vault];
        uint256 p = pendingPerformanceShares[vault];
        uint256 shares = m + p;
        if (shares == 0) revert NothingToHarvest();
        pendingManagementShares[vault] = 0;
        pendingPerformanceShares[vault] = 0;

        uint256 before = usdg.balanceOf(address(this));
        IERC4626(vault).redeem(shares, address(this), address(this));
        assets = usdg.balanceOf(address(this)) - before;
        if (assets < minAssets) revert BadParam();

        uint256 perfAssets = Math.mulDiv(assets, p, shares);
        uint256 toStakers = 0;
        IProjectTokenHooks h = hooks;
        if (address(h) != address(0) && h.rewardsActive()) {
            toStakers = Math.mulDiv(perfAssets, stakerShareBps, 10_000);
        }
        uint256 toTreasury = assets - toStakers;
        treasuryBalance += toTreasury;
        if (toStakers != 0) {
            usdg.forceApprove(address(h), toStakers);
            h.notifyRewards(toStakers);
        }
        emit Harvested(vault, assets, toStakers, toTreasury);
    }
    // slither-disable-end reentrancy-balance
    // slither-disable-end unused-return

    function withdrawTreasury(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (amount > treasuryBalance) revert InsufficientTreasury();
        treasuryBalance -= amount;
        usdg.safeTransfer(to, amount);
        emit TreasuryWithdrawn(to, amount);
    }
}
