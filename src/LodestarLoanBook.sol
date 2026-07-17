// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LodestarOracle} from "./LodestarOracle.sol";
import {LodestarPool} from "./LodestarPool.sol";

/// @title LodestarLoanBook (v1.3)
/// @notice Fixed-term, no-liquidation loans on Flare. Lock yield-bearing collateral
///         (FXRP, sFLR), receive USDT0 at a tier LTV, repay by a deadline. Price crashes
///         never liquidate you — only the calendar can.
///
///         v1.3 settlement redesign (drives every change in this file):
///         - Descending (Dutch) settlement floor: starts at `settleStartBps` of FTSO value
///           when the loan defaults and decays linearly to `settleFloorMinBps` over
///           `settleDecayPeriod`. Guarantees settlement liveness in a crash without ever
///           letting a keeper underprice a fresh default.
///         - Two settlement paths: `buyout` (anyone pays stable at the current floor and
///           takes the collateral in-kind — zero DEX dependency, any size) and `settleSwap`
///           (keeper routes the sale through any owner-whitelisted router with arbitrary
///           calldata; the contract only checks the stable balance delta clears the floor).
///         - Last-good oracle price is cached so an FTSO outage decays the floor from a real
///           reference instead of dropping it to zero.
///         - Rollover re-checks LTV at current prices (a calendar extension must re-qualify);
///           `addCollateral` is the cure path.
///         - The borrow fee is netted from disbursement at open, so a defaulter has always
///           paid it and repay is principal-only.
///         - Stable reserve cuts and penalties accumulate in this contract as a first-loss
///           buffer that automatically tops up lender shortfalls at settlement.
contract LodestarLoanBook is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct Tier {
        uint16 ltvBps; // loan-to-value in bps
        uint32 duration; // seconds
        uint16 feeBps; // one-time fee in bps of principal, netted from disbursement
    }

    /// @dev Packed to 7 storage slots. uint128 comfortably holds any realistic stable
    ///      amount / usd18 value.
    struct Loan {
        address borrower;
        address collateral;
        uint256 collAmount;
        uint128 principal; // stable owed (fee was netted at disbursement)
        uint128 fee; // one-time stable fee charged at open (record only, not owed)
        uint128 principalUsd18; // usd18 principal recorded at open (for exposure accounting)
        uint64 openedAt;
        uint64 dueAt;
        bool active;
        uint128 openRate; // collateral share->underlying rate at open (1e18), for yield-skim
        uint128 impairedLoss; // stable loss currently marked into the pool for this loan
    }

    // --- immutable wiring ---
    LodestarPool public immutable pool;
    LodestarOracle public immutable oracle;
    IERC20 public immutable stable;
    uint8 public immutable stableDecimals;
    uint256 public immutable stableUnit; // 10**stableDecimals, cached to avoid EXP in the hot path

    // --- params (owner-set; intended to sit behind a timelock/multisig in prod) ---
    address public reserve; // recipient of owner reserve withdrawals + yield-skim tokens
    uint64 public gracePeriod = 48 hours;
    uint16 public keeperBps = 500; // % of collateral to the settling keeper (settleSwap only)
    uint128 public keeperCapUsd18 = 500e18; // USD cap on the keeper bounty
    uint16 public penaltyBps = 500; // % of principal to the reserve buffer on default
    uint16 public feeReserveBps = 2000; // % of every fee into the reserve buffer, rest to lenders
    uint16 public settleStartBps = 10_000; // Dutch floor at the moment of default
    uint16 public settleFloorMinBps = 8_500; // Dutch floor after full decay
    uint32 public settleDecayPeriod = 24 hours; // time to decay from start to min
    uint32 public maxLoanLife = 90 days;
    uint64 public oracleFallbackDelay = 7 days; // past due this long, settle can use the cached price
    bool public paused; // blocks NEW borrows only; repay/rollover/settle stay open (non-custodial)
    uint16 public yieldSkimBps; // 0 = borrower keeps all collateral appreciation (default; cap 50%)
    uint128 public minPrincipal; // dust guard: smallest loan the book will write

    /// @dev With the cached price as reference, the floor decays to zero over this window
    ///      once past `oracleFallbackDelay`, so a dead oracle can delay settlement but
    ///      never brick it, while a merely-transient outage can't be used to underprice.
    uint64 public constant ORACLE_DOWN_DECAY = 30 days;

    mapping(address => Tier[]) public tiers; // per-collateral tiers
    mapping(address => uint256) public exposureUsd18; // outstanding principal per collateral (usd18)
    mapping(address => uint256) public exposureCapUsd18; // 0 = uncapped
    mapping(address => bool) public routerAllowed; // routers settleSwap may call
    mapping(address => uint256) public lastPrice18; // last good oracle USD price per whole token
    mapping(address => uint64) public lastPriceAt;
    mapping(uint256 => Loan) public loans;
    uint256 public nextLoanId = 1;
    uint256 public reserveBalance; // stable held here as the first-loss buffer

    mapping(address => uint256) private _unitCache; // 10**decimals per collateral

    event LoanOpened(
        uint256 indexed id,
        address indexed borrower,
        address indexed collateral,
        uint256 collAmount,
        uint256 principal,
        uint256 fee,
        uint64 dueAt
    );
    event LoanRepaid(uint256 indexed id, address payer);
    event LoanRolled(uint256 indexed id, uint64 newDueAt, uint256 addFee);
    event CollateralAdded(uint256 indexed id, address indexed payer, uint256 amount);
    event LoanImpaired(uint256 indexed id, uint256 markedLoss);
    event LoanSettled(
        uint256 indexed id, address indexed settler, bool buyout, uint256 proceeds, uint256 surplus, bool shortfall
    );
    event ReserveCovered(uint256 indexed id, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);
    event TierAdded(address indexed collateral, uint16 ltvBps, uint32 duration, uint16 feeBps);
    event RouterAllowed(address indexed router, bool allowed);
    event YieldSkimmed(uint256 indexed id, address indexed collateral, uint256 amount);

    error NotSupported();
    error BadTier();
    error CapExceeded();
    error NotActive();
    error NotYetDefaulted();
    error Expired();
    error BadParam();
    error Paused();
    error OracleDown();
    error RouterNotAllowed();
    error SwapFailed();
    error SwapIncomplete();
    error BelowFloor();
    error CostAboveMax();
    error Undercollateralized();

    constructor(LodestarPool _pool, LodestarOracle _oracle, address _reserve, address _owner) Ownable(_owner) {
        if (_reserve == address(0)) revert BadParam();
        pool = _pool;
        oracle = _oracle;
        stable = IERC20(_pool.asset());
        stableDecimals = IERC20Metadata(_pool.asset()).decimals();
        stableUnit = 10 ** stableDecimals;
        minPrincipal = uint128(10 * stableUnit);
        reserve = _reserve;
    }

    // ------------------------------------------------------------------ admin
    function addTier(address collateral, uint16 ltvBps, uint32 duration, uint16 feeBps) external onlyOwner {
        // 70% LTV is the hard ceiling for a no-liquidation book: nothing this protocol
        // should ever hold survives a term at higher leverage (see the drawdown study).
        if (ltvBps > 7000 || feeBps > 2000 || duration == 0 || duration > maxLoanLife) revert BadParam();
        tiers[collateral].push(Tier(ltvBps, duration, feeBps));
        emit TierAdded(collateral, ltvBps, duration, feeBps);
    }

    function setExposureCap(address collateral, uint256 capUsd18) external onlyOwner {
        exposureCapUsd18[collateral] = capUsd18;
    }

    function setRouterAllowed(address router, bool allowed) external onlyOwner {
        // Only list routers that cannot move third-party funds (standard DEX routers):
        // settleSwap hands them a bounded collateral allowance plus keeper calldata.
        routerAllowed[router] = allowed;
        emit RouterAllowed(router, allowed);
    }

    function setReserve(address _reserve) external onlyOwner {
        if (_reserve == address(0)) revert BadParam();
        reserve = _reserve;
    }

    function setRiskParams(uint64 grace, uint16 keeper_, uint16 penalty_, uint16 feeReserve_) external onlyOwner {
        if (keeper_ > 1000 || penalty_ > 2000 || feeReserve_ > 10_000 || grace > 14 days) revert BadParam();
        gracePeriod = grace;
        keeperBps = keeper_;
        penaltyBps = penalty_;
        feeReserveBps = feeReserve_;
    }

    /// @notice Dutch settlement curve: floor starts at `startBps` of oracle value when a loan
    ///         defaults and decays linearly to `minBps` over `period`.
    function setSettleCurve(uint16 startBps, uint16 minBps, uint32 period) external onlyOwner {
        if (minBps < 5000 || startBps < minBps || startBps > 10_500) revert BadParam();
        if (period < 1 hours || period > 7 days) revert BadParam();
        settleStartBps = startBps;
        settleFloorMinBps = minBps;
        settleDecayPeriod = period;
    }

    function setKeeperCapUsd18(uint128 capUsd18) external onlyOwner {
        if (capUsd18 == 0 || capUsd18 > 10_000e18) revert BadParam();
        keeperCapUsd18 = capUsd18;
    }

    function setMinPrincipal(uint128 amount) external onlyOwner {
        if (amount > 1000 * stableUnit) revert BadParam();
        minPrincipal = amount;
    }

    /// @notice Pause new borrows in an emergency. Existing loans, repay, and settlement are unaffected.
    function setPaused(bool p) external onlyOwner {
        paused = p;
    }

    /// @notice How long past a deadline a loan can settle on the cached price if FTSO is down (bounded).
    function setOracleFallbackDelay(uint64 d) external onlyOwner {
        if (d < 1 days || d > 30 days) revert BadParam();
        oracleFallbackDelay = d;
    }

    /// @notice Share (bps, capped at 50%) of collateral staking-appreciation routed to the reserve on repay.
    /// @dev Only bites on yield-bearing collateral (sFLR/stXRP) that appreciated during the loan.
    function setYieldSkimBps(uint16 bps) external onlyOwner {
        if (bps > 5000) revert BadParam();
        yieldSkimBps = bps;
    }

    /// @notice Withdraw protocol revenue from the first-loss buffer to the reserve address.
    function withdrawReserve(uint256 amount) external onlyOwner {
        reserveBalance -= amount; // reverts on underflow
        stable.safeTransfer(reserve, amount);
        emit ReserveWithdrawn(reserve, amount);
    }

    // ------------------------------------------------------------------ views
    function tierCount(address collateral) external view returns (uint256) {
        return tiers[collateral].length;
    }

    function isDefaulted(uint256 id) public view returns (bool) {
        Loan storage l = loans[id];
        return l.active && block.timestamp > uint256(l.dueAt) + gracePeriod;
    }

    /// @notice Current Dutch-floor level for a loan, in bps of oracle value.
    function currentFloorBps(uint256 id) public view returns (uint16) {
        Loan storage l = loans[id];
        uint256 defaultAt = uint256(l.dueAt) + gracePeriod;
        if (block.timestamp <= defaultAt) return settleStartBps;
        uint256 t = block.timestamp - defaultAt;
        if (t >= settleDecayPeriod) return settleFloorMinBps;
        return uint16(settleStartBps - (uint256(settleStartBps - settleFloorMinBps) * t) / settleDecayPeriod);
    }

    /// @notice Stable cost to buy out a defaulted loan's collateral right now.
    /// @dev Reverts OracleDown inside the fallback delay if FTSO is unavailable.
    function buyoutCost(uint256 id) external returns (uint256) {
        Loan storage l = loans[id];
        if (!l.active) revert NotActive();
        return _floorStable(l, l.collAmount, currentFloorBps(id));
    }

    // ------------------------------------------------------------------ borrow
    function open(address collateral, uint256 collAmount, uint256 tierIndex)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (paused) revert Paused();
        Tier[] storage ts = tiers[collateral];
        if (ts.length == 0) revert NotSupported();
        if (tierIndex >= ts.length) revert BadTier();
        Tier memory t = ts[tierIndex];

        // Measure actually-received collateral (fee-on-transfer / non-standard token safe).
        {
            uint256 balBefore = IERC20(collateral).balanceOf(address(this));
            IERC20(collateral).safeTransferFrom(msg.sender, address(this), collAmount);
            collAmount = IERC20(collateral).balanceOf(address(this)) - balBefore;
        }
        if (collAmount == 0) revert BadParam();

        uint256 collValue18 = oracle.usdValue18(collateral, collAmount);
        _cachePrice(collateral, collValue18, collAmount);
        uint256 principalUsd18 = (collValue18 * t.ltvBps) / 10_000;
        {
            uint256 cap = exposureCapUsd18[collateral];
            if (cap != 0 && exposureUsd18[collateral] + principalUsd18 > cap) revert CapExceeded();
        }
        exposureUsd18[collateral] += principalUsd18;

        uint256 principal = _usd18ToStable(principalUsd18);
        if (principal < minPrincipal || principal == 0) revert BadParam();
        uint256 fee = (principal * t.feeBps) / 10_000;

        id = nextLoanId++;
        uint64 dueAt = uint64(block.timestamp + t.duration);
        loans[id] = Loan({
            borrower: msg.sender,
            collateral: collateral,
            collAmount: collAmount,
            principal: principal.toUint128(),
            fee: fee.toUint128(),
            principalUsd18: principalUsd18.toUint128(),
            openedAt: uint64(block.timestamp),
            dueAt: dueAt,
            active: true,
            openRate: oracle.rateOf(collateral).toUint128(),
            impairedLoss: 0
        });

        // Fee is netted from disbursement: the borrower receives principal - fee and the fee
        // is earned unconditionally (a defaulter has already paid it). The lender share simply
        // stays in the pool as instant yield; the reserve cut moves into the first-loss buffer.
        pool.disburse(msg.sender, principal - fee, principal);
        uint256 rcut = (fee * feeReserveBps) / 10_000;
        if (rcut > 0) {
            pool.payout(address(this), rcut);
            reserveBalance += rcut;
        }
        emit LoanOpened(id, msg.sender, collateral, collAmount, principal, fee, dueAt);
    }

    /// @notice Repay the principal (fee was netted at open) and reclaim collateral,
    ///         including any yield the LST accrued.
    function repay(uint256 id) external nonReentrant {
        Loan storage L = loans[id];
        if (!L.active) revert NotActive();

        L.active = false;
        _reduceExposure(L.collateral, L.principalUsd18);
        _clearImpairment(L, id);

        pool.pull(msg.sender, L.principal);
        pool.onPrincipalReturned(L.principal);

        _returnCollateral(L, id);
        emit LoanRepaid(id, msg.sender);
    }

    /// @dev Returns collateral to the borrower, routing a `yieldSkimBps` share of any staking
    ///      appreciation (measured via the collateral's open vs. current rate) to the reserve.
    function _returnCollateral(Loan storage L, uint256 id) internal {
        uint256 ret = L.collAmount;
        uint16 skimBps = yieldSkimBps;
        if (skimBps != 0 && L.openRate != 0) {
            uint256 nowRate = oracle.rateOf(L.collateral);
            if (nowRate > L.openRate) {
                uint256 gain = (L.collAmount * (nowRate - L.openRate)) / nowRate;
                uint256 skim = (gain * skimBps) / 10_000;
                if (skim != 0) {
                    ret -= skim;
                    IERC20(L.collateral).safeTransfer(reserve, skim);
                    emit YieldSkimmed(id, L.collateral, skim);
                }
            }
        }
        IERC20(L.collateral).safeTransfer(L.borrower, ret);
    }

    /// @notice Add collateral to an active loan (the cure path for a rollover health check).
    function addCollateral(uint256 id, uint256 amount) external nonReentrant {
        Loan storage L = loans[id];
        if (!L.active) revert NotActive();
        uint256 balBefore = IERC20(L.collateral).balanceOf(address(this));
        IERC20(L.collateral).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(L.collateral).balanceOf(address(this)) - balBefore;
        if (received == 0) revert BadParam();
        L.collAmount += received;
        emit CollateralAdded(id, msg.sender, received);
    }

    /// @notice Extend a loan before its deadline by paying another tier fee (up to maxLoanLife).
    /// @dev v1.3: the position must re-qualify at the chosen tier's LTV at CURRENT prices.
    ///      The calendar is this protocol's only defense, so every calendar extension has to
    ///      re-underwrite. Cure an undercollateralized position via addCollateral first.
    function rollover(uint256 id, uint256 tierIndex) external nonReentrant {
        Loan storage L = loans[id];
        if (!L.active) revert NotActive();
        if (block.timestamp > L.dueAt) revert Expired();
        Tier[] storage ts = tiers[L.collateral];
        if (tierIndex >= ts.length) revert BadTier();

        uint256 collValue18 = oracle.usdValue18(L.collateral, L.collAmount);
        _cachePrice(L.collateral, collValue18, L.collAmount);
        uint256 principalAsUsd18 = (uint256(L.principal) * 1e18) / stableUnit;
        if ((collValue18 * ts[tierIndex].ltvBps) / 10_000 < principalAsUsd18) revert Undercollateralized();

        uint256 addFee = (uint256(L.principal) * ts[tierIndex].feeBps) / 10_000;
        uint64 newDue = uint64(block.timestamp + ts[tierIndex].duration);
        if (newDue > uint64(L.openedAt) + maxLoanLife) revert Expired();

        pool.pull(msg.sender, addFee);
        uint256 rcut = (addFee * feeReserveBps) / 10_000;
        if (rcut > 0) {
            pool.payout(address(this), rcut);
            reserveBalance += rcut;
        }

        L.dueAt = newDue;
        emit LoanRolled(id, newDue, addFee);
    }

    // ------------------------------------------------------------------ default handling
    /// @notice Mark a defaulted loan's expected loss into the pool immediately (permissionless).
    ///         Prevents lenders who watch the chain from exiting at par ahead of a markdown.
    ///         Re-callable to track the oracle; fully reversed if the loan is later repaid,
    ///         trued up at settlement.
    function impair(uint256 id) external nonReentrant {
        Loan storage L = loans[id];
        if (!isDefaulted(id)) revert NotYetDefaulted();

        uint256 collValue18 = oracle.usdValue18(L.collateral, L.collAmount); // reverts while FTSO is down
        _cachePrice(L.collateral, collValue18, L.collAmount);
        uint256 est = (_usd18ToStable(collValue18) * (10_000 - keeperBps)) / 10_000;

        uint256 principal = L.principal;
        uint256 newLoss = est >= principal ? 0 : principal - est;
        uint256 oldLoss = L.impairedLoss;
        if (newLoss > oldLoss) pool.impair(newLoss - oldLoss);
        else if (oldLoss > newLoss) pool.unimpair(oldLoss - newLoss);
        L.impairedLoss = newLoss.toUint128();
        emit LoanImpaired(id, newLoss);
    }

    /// @notice Buy a defaulted loan's collateral outright at the current Dutch floor.
    ///         No router, no DEX, no size limit: the buyer sources liquidity anywhere.
    /// @param maxCost Buyer's protection against a floor move between quote and execution.
    function buyout(uint256 id, uint256 maxCost) external nonReentrant {
        Loan storage L = loans[id];
        if (!L.active) revert NotActive();
        if (block.timestamp <= uint256(L.dueAt) + gracePeriod) revert NotYetDefaulted();

        uint16 floorBps = currentFloorBps(id);
        L.active = false;
        _reduceExposure(L.collateral, L.principalUsd18);

        uint256 cost = _floorStable(L, L.collAmount, floorBps);
        if (cost > maxCost) revert CostAboveMax();

        if (cost > 0) stable.safeTransferFrom(msg.sender, address(this), cost);
        IERC20(L.collateral).safeTransfer(msg.sender, L.collAmount);

        _clearImpairment(L, id);
        (uint256 surplus, bool shortfall) = _distribute(L, cost, id);
        emit LoanSettled(id, msg.sender, true, cost, surplus, shortfall);
    }

    /// @notice Settle a defaulted loan by selling the collateral through a whitelisted router.
    ///         The keeper supplies the router calldata; this contract only verifies that the
    ///         full sale amount left and the stable received clears max(minOut, Dutch floor).
    function settleSwap(uint256 id, address router, bytes calldata swapData, uint256 minOut) external nonReentrant {
        Loan storage L = loans[id];
        if (!L.active) revert NotActive();
        if (block.timestamp <= uint256(L.dueAt) + gracePeriod) revert NotYetDefaulted();
        if (!routerAllowed[router]) revert RouterNotAllowed();

        uint16 floorBps = currentFloorBps(id);
        L.active = false;
        _reduceExposure(L.collateral, L.principalUsd18);

        uint256 proceeds;
        {
            _refreshPrice(L.collateral);
            uint256 bounty = _bountyAmount(L);
            uint256 toSell = L.collAmount - bounty;
            if (bounty > 0) IERC20(L.collateral).safeTransfer(msg.sender, bounty);

            uint256 floor = _floorStable(L, toSell, floorBps);
            if (minOut < floor) minOut = floor;

            proceeds = _swapViaRouter(L.collateral, router, swapData, toSell);
            if (proceeds < minOut) revert BelowFloor();
        }

        _clearImpairment(L, id);
        (uint256 surplus, bool shortfall) = _distribute(L, proceeds, id);
        emit LoanSettled(id, msg.sender, false, proceeds, surplus, shortfall);
    }

    /// @dev Executes the keeper's calldata against the whitelisted router under a bounded
    ///      allowance, and requires exactly `toSell` collateral to have left (custody stays
    ///      exact) while measuring proceeds as the stable balance delta.
    function _swapViaRouter(address collateral, address router, bytes calldata swapData, uint256 toSell)
        internal
        returns (uint256 proceeds)
    {
        uint256 collBefore = IERC20(collateral).balanceOf(address(this));
        uint256 stableBefore = stable.balanceOf(address(this));

        IERC20(collateral).forceApprove(router, toSell);
        (bool ok,) = router.call(swapData);
        if (!ok) revert SwapFailed();
        IERC20(collateral).forceApprove(router, 0);

        if (IERC20(collateral).balanceOf(address(this)) != collBefore - toSell) revert SwapIncomplete();
        proceeds = stable.balanceOf(address(this)) - stableBefore;
    }

    /// @dev Keeper bounty in collateral: keeperBps of the collateral, USD-capped, and zero when
    ///      the borrower settles their own default (no reward for defaulting).
    function _bountyAmount(Loan storage L) internal returns (uint256 b) {
        if (msg.sender == L.borrower || keeperBps == 0) return 0;
        b = (L.collAmount * keeperBps) / 10_000;
        uint256 p18 = lastPrice18[L.collateral];
        if (p18 != 0) {
            uint256 capTokens = (uint256(keeperCapUsd18) * _unit(L.collateral)) / p18;
            if (b > capTokens) b = capTokens;
        }
    }

    /// @dev Stable value of `collPortion` at `floorBps` of the oracle price. If FTSO is down:
    ///      reverts inside `oracleFallbackDelay` past due, afterwards decays the cached-price
    ///      floor to zero over ORACLE_DOWN_DECAY so settlement can never be bricked for good.
    function _floorStable(Loan storage L, uint256 collPortion, uint16 floorBps) internal returns (uint256 floor) {
        try oracle.usdValue18(L.collateral, collPortion) returns (uint256 v18) {
            _cachePrice(L.collateral, v18, collPortion);
            floor = (_usd18ToStable(v18) * floorBps) / 10_000;
        } catch {
            uint256 fallbackAt = uint256(L.dueAt) + oracleFallbackDelay;
            if (block.timestamp <= fallbackAt) revert OracleDown();
            uint256 p18 = lastPrice18[L.collateral];
            if (p18 == 0) return 0; // no reference ever cached (cannot happen after open)
            uint256 v18 = (p18 * collPortion) / _unit(L.collateral);
            floor = (_usd18ToStable(v18) * settleFloorMinBps) / 10_000;
            uint256 t = block.timestamp - fallbackAt;
            floor = t >= ORACLE_DOWN_DECAY ? 0 : (floor * (ORACLE_DOWN_DECAY - t)) / ORACLE_DOWN_DECAY;
        }
    }

    /// @dev Waterfall: principal (reserve buffer covers any shortfall) -> penalty -> surplus
    ///      to borrower. The fee is not in the waterfall: it was collected at open.
    function _distribute(Loan storage L, uint256 proceeds, uint256 id)
        internal
        returns (uint256 remaining, bool shortfall)
    {
        uint256 principal = L.principal;
        remaining = proceeds;

        uint256 payPrincipal = remaining >= principal ? principal : remaining;
        remaining -= payPrincipal;
        if (payPrincipal > 0) stable.safeTransfer(address(pool), payPrincipal);

        uint256 gap = principal - payPrincipal;
        if (gap > 0 && reserveBalance > 0) {
            uint256 cover = gap <= reserveBalance ? gap : reserveBalance;
            reserveBalance -= cover;
            stable.safeTransfer(address(pool), cover);
            gap -= cover;
            emit ReserveCovered(id, cover);
        }
        shortfall = gap > 0; // whatever the buffer couldn't cover is a realized lender loss
        pool.onPrincipalReturned(principal);

        uint256 penalty = (principal * penaltyBps) / 10_000;
        uint256 payPenalty = remaining >= penalty ? penalty : remaining;
        remaining -= payPenalty;
        if (payPenalty > 0) reserveBalance += payPenalty; // stays in this contract

        if (remaining > 0) stable.safeTransfer(L.borrower, remaining);
    }

    // ------------------------------------------------------------------ internal
    function _clearImpairment(Loan storage L, uint256 id) internal {
        uint256 marked = L.impairedLoss;
        if (marked > 0) {
            pool.unimpair(marked);
            L.impairedLoss = 0;
            emit LoanImpaired(id, 0);
        }
    }

    function _reduceExposure(address collateral, uint256 principalUsd18) internal {
        uint256 e = exposureUsd18[collateral];
        exposureUsd18[collateral] = principalUsd18 >= e ? 0 : e - principalUsd18;
    }

    /// @dev Cache the implied whole-token price from a successful oracle valuation.
    function _cachePrice(address collateral, uint256 value18, uint256 amount) internal {
        if (amount == 0) return;
        uint256 p18 = (value18 * _unit(collateral)) / amount;
        if (p18 == 0) return;
        lastPrice18[collateral] = p18;
        lastPriceAt[collateral] = uint64(block.timestamp);
    }

    function _refreshPrice(address collateral) internal {
        try oracle.priceUsd18(collateral) returns (uint256 p18) {
            if (p18 != 0) {
                lastPrice18[collateral] = p18;
                lastPriceAt[collateral] = uint64(block.timestamp);
            }
        } catch {} // best-effort: settlement handles a down oracle explicitly
    }

    function _unit(address token) internal returns (uint256 u) {
        u = _unitCache[token];
        if (u == 0) {
            u = 10 ** IERC20Metadata(token).decimals();
            _unitCache[token] = u;
        }
    }

    function _usd18ToStable(uint256 usd18) internal view returns (uint256) {
        return (usd18 * stableUnit) / 1e18;
    }
}
