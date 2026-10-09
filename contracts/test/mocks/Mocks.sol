// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "../../src/interfaces/external/IAggregatorV3.sol";
import {ISwapRouter02} from "../../src/interfaces/external/ISwapRouter02.sol";
import {
    IMorpho,
    IMorphoOracle,
    IIrm,
    IMorphoFlashLoanCallback,
    IMorphoSupplyCollateralCallback,
    Id,
    MarketParams,
    Market
} from "../../src/interfaces/external/IMorpho.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @dev Test-only ERC-20 (also stands in for the externally launched $PAIR token in tests).
contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockAggregator is IAggregatorV3 {
    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    uint8 public immutable decimals;
    uint80 public latestRound;
    mapping(uint80 => Round) public rounds;

    constructor(uint8 d, int256 initial) {
        decimals = d;
        if (initial != 0) setPrice(initial);
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function setPrice(int256 answer) public {
        latestRound += 1;
        rounds[latestRound] = Round(answer, block.timestamp, block.timestamp, latestRound);
    }

    function setRound(uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) external {
        rounds[id] = Round(answer, startedAt, updatedAt, answeredInRound);
        if (id > latestRound) latestRound = id;
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[id];
        require(r.updatedAt != 0, "No data present");
        return (id, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latestRound];
        return (latestRound, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
    }
}

/// @dev Fills swaps at the oracle price minus an adverse `slippageBps` (mints output, keeps input).
contract MockSwapRouter is ISwapRouter02 {
    using SafeERC20 for IERC20;

    IPriceOracle public oracle;
    uint256 public slippageBps;
    uint256 public priceSkewBps; // extra adverse skew to simulate a manipulated pool

    constructor(IPriceOracle oracle_) {
        oracle = oracle_;
    }

    function setSlippageBps(uint256 bps) external {
        slippageBps = bps;
    }

    function setPriceSkewBps(uint256 bps) external {
        priceSkewBps = bps;
    }

    function _ends(bytes memory path) internal pure returns (address first, address last) {
        uint256 len = path.length;
        assembly {
            first := shr(96, mload(add(path, 32)))
            last := shr(96, mload(add(add(path, 32), sub(len, 20))))
        }
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 out) {
        (address tokenIn, address tokenOut) = _ends(p.path);
        out = oracle.convert(tokenIn, p.amountIn, tokenOut) * (10_000 - slippageBps - priceSkewBps) / 10_000;
        require(out >= p.amountOutMinimum, "Too little received");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        MockERC20(tokenOut).mint(p.recipient, out);
    }

    function exactOutput(ExactOutputParams calldata p) external payable returns (uint256 amountIn) {
        (address tokenOut, address tokenIn) = _ends(p.path);
        amountIn = oracle.convert(tokenOut, p.amountOut, tokenIn) * (10_000 + slippageBps + priceSkewBps) / 10_000 + 1;
        require(amountIn <= p.amountInMaximum, "Too much requested");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(p.recipient, p.amountOut);
    }
}

contract MockIrm is IIrm {
    uint256 public rate; // per second, 1e18-scaled

    function setRate(uint256 r) external {
        rate = r;
    }

    function borrowRateView(MarketParams memory, Market memory) external view returns (uint256) {
        return rate;
    }
}

/// @dev Morpho-style oracle priced off the protocol oracle: loan units per collateral unit, scaled 1e36.
contract MockMorphoOracle is IMorphoOracle {
    IPriceOracle public oracle;
    address public collateral; // underlying (USDG) if wrapper is set
    address public loan;
    ERC4626 public wrapper;
    uint256 public override_;

    constructor(IPriceOracle oracle_, address collateral_, address loan_, ERC4626 wrapper_) {
        oracle = oracle_;
        collateral = collateral_;
        loan = loan_;
        wrapper = wrapper_;
    }

    function setOverride(uint256 p) external {
        override_ = p;
    }

    function price() external view returns (uint256) {
        if (override_ != 0) return override_;
        uint256 units = 1e18; // collateral-token units
        uint256 underlying = address(wrapper) == address(0) ? units : wrapper.convertToAssets(units);
        return oracle.convert(collateral, underlying, loan) * 1e18;
    }
}

contract MockVault4626 is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock steakUSDG", "mUSDGv") ERC4626(asset_) {}
}

/// @dev Faithful-enough Morpho Blue: share math with virtual shares, health checks on borrow/withdrawCollateral,
///      liquidity checks, interest accrual through the IRM, flash loans and a simplified liquidation.
contract MockMorpho is IMorpho {
    using SafeERC20 for IERC20;

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    mapping(Id => MarketParams) public params;
    mapping(Id => Market) internal _market;
    mapping(Id => mapping(address => Position)) internal _pos;

    function createMarket(MarketParams memory p) external returns (Id id) {
        id = Id.wrap(keccak256(abi.encode(p)));
        params[id] = p;
        _market[id].lastUpdate = uint128(block.timestamp);
    }

    function idOf(MarketParams memory p) public pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(p)));
    }

    function idToMarketParams(Id id) external view returns (address, address, address, address, uint256) {
        MarketParams memory p = params[id];
        return (p.loanToken, p.collateralToken, p.oracle, p.irm, p.lltv);
    }

    function market(Id id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        Market memory m = _market[id];
        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, m.fee);
    }

    function position(Id id, address user) external view returns (uint256, uint128, uint128) {
        Position memory p = _pos[id][user];
        return (p.supplyShares, p.borrowShares, p.collateral);
    }

    function accrueInterest(MarketParams memory mp) public {
        Id id = idOf(mp);
        Market storage m = _market[id];
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0) return;
        if (m.totalBorrowAssets != 0 && mp.irm != address(0)) {
            uint256 rate = IIrm(mp.irm).borrowRateView(mp, m);
            uint256 first = rate * elapsed;
            uint256 second = Math.mulDiv(first, first, 2 * WAD);
            uint256 third = Math.mulDiv(second, first, 3 * WAD);
            uint256 interest = Math.mulDiv(m.totalBorrowAssets, first + second + third, WAD);
            m.totalBorrowAssets += uint128(interest);
            m.totalSupplyAssets += uint128(interest);
        }
        m.lastUpdate = uint128(block.timestamp);
    }

    function supply(MarketParams memory mp, uint256 assets, address onBehalf) external {
        accrueInterest(mp);
        Id id = idOf(mp);
        Market storage m = _market[id];
        uint256 shares = Math.mulDiv(assets, m.totalSupplyShares + VIRTUAL_SHARES, m.totalSupplyAssets + VIRTUAL_ASSETS);
        _pos[id][onBehalf].supplyShares += shares;
        m.totalSupplyShares += uint128(shares);
        m.totalSupplyAssets += uint128(assets);
        IERC20(mp.loanToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @dev Lender withdrawal (models "recall": lenders pulling idle liquidity).
    function withdraw(MarketParams memory mp, uint256 assets, address onBehalf, address receiver) external {
        require(msg.sender == onBehalf, "unauthorized");
        accrueInterest(mp);
        Id id = idOf(mp);
        Market storage m = _market[id];
        uint256 shares = Math.mulDiv(
            assets, m.totalSupplyShares + VIRTUAL_SHARES, m.totalSupplyAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil
        );
        _pos[id][onBehalf].supplyShares -= shares;
        m.totalSupplyShares -= uint128(shares);
        m.totalSupplyAssets -= uint128(assets);
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "insufficient liquidity");
        IERC20(mp.loanToken).safeTransfer(receiver, assets);
    }

    function supplyCollateral(MarketParams memory mp, uint256 assets, address onBehalf, bytes memory data) external {
        Id id = idOf(mp);
        _pos[id][onBehalf].collateral += uint128(assets);
        if (data.length != 0) IMorphoSupplyCollateralCallback(msg.sender).onMorphoSupplyCollateral(assets, data);
        IERC20(mp.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdrawCollateral(MarketParams memory mp, uint256 assets, address onBehalf, address receiver) external {
        require(msg.sender == onBehalf, "unauthorized");
        accrueInterest(mp);
        Id id = idOf(mp);
        _pos[id][onBehalf].collateral -= uint128(assets);
        require(_healthy(mp, id, onBehalf), "insufficient collateral");
        IERC20(mp.collateralToken).safeTransfer(receiver, assets);
    }

    function borrow(MarketParams memory mp, uint256 assets, uint256, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        require(msg.sender == onBehalf, "unauthorized");
        accrueInterest(mp);
        Id id = idOf(mp);
        Market storage m = _market[id];
        uint256 shares = Math.mulDiv(
            assets, m.totalBorrowShares + VIRTUAL_SHARES, m.totalBorrowAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil
        );
        _pos[id][onBehalf].borrowShares += uint128(shares);
        m.totalBorrowShares += uint128(shares);
        m.totalBorrowAssets += uint128(assets);
        require(_healthy(mp, id, onBehalf), "insufficient collateral");
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "insufficient liquidity");
        IERC20(mp.loanToken).safeTransfer(receiver, assets);
        return (assets, shares);
    }

    function repay(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        accrueInterest(mp);
        Id id = idOf(mp);
        Market storage m = _market[id];
        if (shares != 0) {
            assets = Math.mulDiv(
                shares, m.totalBorrowAssets + VIRTUAL_ASSETS, m.totalBorrowShares + VIRTUAL_SHARES, Math.Rounding.Ceil
            );
        } else {
            shares = Math.mulDiv(assets, m.totalBorrowShares + VIRTUAL_SHARES, m.totalBorrowAssets + VIRTUAL_ASSETS);
        }
        _pos[id][onBehalf].borrowShares -= uint128(shares);
        m.totalBorrowShares -= uint128(shares);
        m.totalBorrowAssets = assets > m.totalBorrowAssets ? 0 : m.totalBorrowAssets - uint128(assets);
        IERC20(mp.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        IERC20(token).safeTransfer(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @dev Simplified liquidation: seizes all collateral and wipes the debt of an unhealthy borrower.
    function liquidate(MarketParams memory mp, address borrower) external {
        accrueInterest(mp);
        Id id = idOf(mp);
        require(!_healthy(mp, id, borrower), "position is healthy");
        Position storage p = _pos[id][borrower];
        Market storage m = _market[id];
        uint256 debt = Math.mulDiv(
            p.borrowShares, m.totalBorrowAssets + VIRTUAL_ASSETS, m.totalBorrowShares + VIRTUAL_SHARES, Math.Rounding.Ceil
        );
        IERC20(mp.loanToken).safeTransferFrom(msg.sender, address(this), debt);
        m.totalBorrowShares -= p.borrowShares;
        m.totalBorrowAssets = debt > m.totalBorrowAssets ? 0 : m.totalBorrowAssets - uint128(debt);
        uint256 seized = p.collateral;
        p.borrowShares = 0;
        p.collateral = 0;
        IERC20(mp.collateralToken).safeTransfer(msg.sender, seized);
    }

    function isHealthy(MarketParams memory mp, address user) external view returns (bool) {
        return _healthy(mp, idOf(mp), user);
    }

    function _healthy(MarketParams memory mp, Id id, address user) internal view returns (bool) {
        Position memory p = _pos[id][user];
        if (p.borrowShares == 0) return true;
        Market memory m = _market[id];
        uint256 borrowed = Math.mulDiv(
            p.borrowShares, m.totalBorrowAssets + VIRTUAL_ASSETS, m.totalBorrowShares + VIRTUAL_SHARES, Math.Rounding.Ceil
        );
        uint256 maxBorrow = Math.mulDiv(
            Math.mulDiv(p.collateral, IMorphoOracle(mp.oracle).price(), 1e36), mp.lltv, WAD
        );
        return maxBorrow >= borrowed;
    }
}
