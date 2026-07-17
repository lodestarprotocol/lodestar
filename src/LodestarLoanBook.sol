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

    /// @dev Borrower-facing terms snapshotted at open so an owner (even a compromised one)
    ///      cannot retroactively rewrite the deal on an already-open loan. Every field here is
    ///      a promise read at the borrower's own repay/settlement; keeping it live would let a
    ///      param change confiscate yield, erase the cure window, or lower the settlement floor
    ///      under a loan the borrower can no longer exit. Owner setters still change the DEFAULTS
    ///      applied to NEW loans. One packed slot.
    struct LoanTerms {
        uint64 grace; // grace window after due before default
        uint32 settleDecayPeriod; // Dutch decay time
        uint16 settleStartBps; // Dutch floor at default
        uint16 settleFloorMinBps; // Dutch floor after full decay
        uint16 skimBps; // yield-skim share applied at repay
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
    mapping(uint256 => LoanTerms) public loanTerms; // per-loan snapshot of the borrower-facing terms
    uint256 public nextLoanId = 1;
    uint256 public reserveBalance; // stable held here as the first-loss buffer

    uint256[] public activeLoanIds; // every open loan, for the withdraw-time impairment sweep
    mapping(uint256 => uint256) private _activeIdx; // 1-based index into activeLoanIds; 0 = not active
    // Bounds the withdraw-time impairment sweep so a mass-crash sweep (worst case ~20k gas/loan,
    // all marks writing) stays well under Flare's ~28M block gas limit and can never brick a
    // withdrawal. 300 loans ≈ 6M gas worst case; the setter is capped at 400 for headroom.
    uint32 public maxActiveLoans = 300;

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
    error ProceedsTooHigh();
    error BelowFloor();
    error CostAboveMax();
    error Undercollateralized();
    error TooManyActiveLoans();

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

    /// @notice Cap on concurrent active loans. Bounds the withdraw-time impairment sweep so a
    ///         redemption can never be gas-bricked. Raise it only as far as the sweep stays
    ///         comfortably under the block gas limit for this chain.
    function setMaxActiveLoans(uint32 n) external onlyOwner {
        // Upper bound keeps the worst-case mass-crash sweep safely under the block gas limit.
        if (n < 50 || n > 400) revert BadParam();
        maxActiveLoans = n;
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
    /// @dev Settlement-aware: the owner can never pull the buffer below the currently-marked
    ///      expected loss (`pool.impairedLoss`), so a compromised/hasty owner cannot front-run a
    ///      known-bad settlement to drain the very cushion that is earmarked to cover it. Only
    ///      genuine surplus above outstanding marked losses is withdrawable.
    function withdrawReserve(uint256 amount) external onlyOwner {
        uint256 earmarked = pool.impairedLoss();
        if (reserveBalance < amount || reserveBalance - amount < earmarked) revert BadParam();
        reserveBalance -= amount;
        stable.safeTransfer(reserve, amount);
        emit ReserveWithdrawn(reserve, amount);
    }

    /// @notice Recover stable accidentally donated to the book (anything above the tracked
    ///         buffer). Keeps `stable.balanceOf(book) == reserveBalance` restorable.
    function sweepStableDonations(address to) external onlyOwner {
        if (to == address(0)) revert BadParam();
        uint256 bal = stable.balanceOf(address(this));
        if (bal > reserveBalance) stable.safeTransfer(to, bal - reserveBalance);
    }

    // ------------------------------------------------------------------ views
    function tierCount(address collateral) external view returns (uint256) {
        return tiers[collateral].length;
    }

    function isDefaulted(uint256 id) public view returns (bool) {
        Loan storage l = loans[id];
        return l.active && block.timestamp > uint256(l.dueAt) + loanTerms[id].grace;
    }

    /// @notice Current Dutch-floor level for a loan, in bps of oracle value. Uses the loan's
    ///         snapshotted curve, not the live one, so the floor is a fixed per-loan promise.
    function currentFloorBps(uint256 id) public view returns (uint16) {
        Loan storage l = loans[id];
        LoanTerms storage tm = loanTerms[id];
        uint256 defaultAt = uint256(l.dueAt) + tm.grace;
        if (block.timestamp <= defaultAt) return tm.settleStartBps;
        uint256 t = block.timestamp - defaultAt;
        if (t >= tm.settleDecayPeriod) return tm.settleFloorMinBps;
        return uint16(tm.settleStartBps - (uint256(tm.settleStartBps - tm.settleFloorMinBps) * t) / tm.settleDecayPeriod);
    }

    /// @notice Stable cost to buy out a defaulted loan's collateral right now.
    /// @dev Reverts OracleDown inside the fallback delay if FTSO is unavailable.
    function buyoutCost(uint256 id) external returns (uint256) {
        if (!loans[id].active) revert NotActive();
        return _settlementFloor(id, loans[id].collAmount);
    }

    /// @dev Current settlement floor (stable) for a portion of a loan's collateral, using the
    ///      loan's snapshotted Dutch curve. Keeps the settlement functions off the stack limit.
    function _settlementFloor(uint256 id, uint256 collPortion) internal returns (uint256) {
        return _floorStable(loans[id], collPortion, currentFloorBps(id), loanTerms[id].settleFloorMinBps);
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
        _snapshotTerms(id); // freeze borrower-facing terms; later param changes can't rewrite this deal
        _addActive(id); // track for the withdraw-time impairment sweep (reverts if over the cap)

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
        _removeActive(id);
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
        uint16 skimBps = loanTerms[id].skimBps; // the skim in force when THIS loan opened
        if (skimBps != 0 && L.openRate != 0) {
            uint256 nowRate = oracle.rateOf(L.collateral);
            // Clamp recognized appreciation to 20% over the (<=90d) term. Real LST staking
            // yield is a few percent; anything beyond this is a manipulated/abnormal rate
            // provider, and we refuse to skim the borrower on it (favours the borrower).
            uint256 maxRate = (uint256(L.openRate) * 12_000) / 10_000;
            if (nowRate > maxRate) nowRate = maxRate;
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
    /// @notice Mark a loan's expected loss into the pool immediately (permissionless).
    ///         Callable on ANY active loan: healthy positions mark zero, underwater positions
    ///         mark the oracle-true gap. This keeps the share price honest mark-to-market the
    ///         moment a crash puts a loan underwater (even mid-term), so no lender can exit at
    ///         par ahead of bad news. It never touches the borrower or the collateral: the mark
    ///         is fully reversed if the price recovers or the loan is repaid, and trued up at
    ///         settlement. Marking assumes default (recovery = collateral value less the keeper
    ///         share), the conservative choice while a repayment is still possible.
    function impair(uint256 id) external nonReentrant {
        if (!loans[id].active) revert NotActive();
        _impairActive(id);
    }

    /// @notice Batch-mark many loans in one call so a keeper can keep the share price honest
    ///         across the whole book during volatility (mitigates the phantom-solvency window
    ///         where an unmarked underwater loan lets an informed lender exit at par). Inactive
    ///         ids are skipped rather than reverting the batch.
    function impairMany(uint256[] calldata ids) external nonReentrant {
        for (uint256 i; i < ids.length; i++) {
            if (loans[ids[i]].active) _impairActive(ids[i]);
        }
    }

    function _impairActive(uint256 id) internal {
        // Value off the live oracle, or the cached last-good price if FTSO is stalled. A crash is
        // exactly when marking matters most and when a feed is most likely to lag, so impair must
        // not depend on a live oracle to close the exit window.
        uint256 price18 = _livePriceOrCache(loans[id].collateral);
        if (price18 == 0) revert OracleDown();
        uint256 delta = _markLoanRaise(id, price18);
        if (delta > 0) pool.impair(delta);
    }

    /// @notice Sweep the whole active book, marking every underwater loan's expected loss into
    ///         the pool (raise-only). Permissionless. The pool calls this on every withdraw and
    ///         redeem, so the share price is always fresh: no lender can exit against a stale,
    ///         too-high price (the phantom-solvency window). Bounded by `maxActiveLoans` so it can
    ///         never gas-brick a withdrawal. A keeper calling it during volatility is then just a
    ///         UI-freshness convenience, not a safety dependency.
    function syncImpairment() external nonReentrant {
        _syncAll();
    }

    function _syncAll() internal {
        uint256 n = activeLoanIds.length;
        if (n == 0) return;
        // Cache each collateral's price once (a book has only a handful of collaterals), then mark
        // every loan from the cached price. Oracle reads are O(collaterals), the loop is O(loans).
        address[] memory cAddr = new address[](n);
        uint256[] memory cPrice = new uint256[](n);
        uint256 cLen;
        uint256 totalDelta;
        for (uint256 i; i < n; i++) {
            uint256 id = activeLoanIds[i];
            address coll = loans[id].collateral;
            uint256 price18;
            bool found;
            for (uint256 j; j < cLen; j++) {
                if (cAddr[j] == coll) {
                    price18 = cPrice[j];
                    found = true;
                    break;
                }
            }
            if (!found) {
                price18 = _livePriceOrCache(coll);
                cAddr[cLen] = coll;
                cPrice[cLen] = price18;
                cLen++;
            }
            if (price18 != 0) totalDelta += _markLoanRaise(id, price18);
        }
        if (totalDelta > 0) pool.impair(totalDelta); // one pool write for the whole sweep
    }

    /// @dev Live oracle price (refreshing the cache) or the last-good cached price if FTSO reverts.
    function _livePriceOrCache(address collateral) internal returns (uint256) {
        try oracle.priceUsd18(collateral) returns (uint256 p18) {
            if (p18 != 0) {
                lastPrice18[collateral] = p18;
                lastPriceAt[collateral] = uint64(block.timestamp);
            }
            return p18;
        } catch {
            return lastPrice18[collateral];
        }
    }

    /// @dev Raise-only high-water mark of a loan's expected loss at a given whole-token price.
    ///      Updates the loan's stored loss and RETURNS the pool-impairment delta so the caller can
    ///      batch a single `pool.impair` across a whole sweep (one pool write instead of N).
    ///      Mid-life impairment may only RAISE the recognized loss; the reversal happens solely at
    ///      close (`_clearImpairment`). A mid-life DOWNWARD re-mark would let an attacker atomically
    ///      deposit -> impair(a recovered loan) -> redeem and skim the reversal. Conservative
    ///      accounting: recognize early, reverse only at realization.
    function _markLoanRaise(uint256 id, uint256 price18) internal returns (uint256 delta) {
        Loan storage L = loans[id];
        uint256 valStable = _usd18ToStable((price18 * L.collAmount) / _unit(L.collateral));
        uint256 est = (valStable * (10_000 - keeperBps)) / 10_000;
        uint256 newLoss = est >= L.principal ? 0 : L.principal - est;
        if (newLoss > L.impairedLoss) {
            delta = newLoss - uint256(L.impairedLoss);
            L.impairedLoss = newLoss.toUint128();
            emit LoanImpaired(id, newLoss);
        }
    }

    function _addActive(uint256 id) internal {
        if (activeLoanIds.length >= maxActiveLoans) revert TooManyActiveLoans();
        activeLoanIds.push(id);
        _activeIdx[id] = activeLoanIds.length; // 1-based
    }

    function _removeActive(uint256 id) internal {
        uint256 idx = _activeIdx[id];
        if (idx == 0) return;
        uint256 lastId = activeLoanIds[activeLoanIds.length - 1];
        activeLoanIds[idx - 1] = lastId;
        _activeIdx[lastId] = idx;
        activeLoanIds.pop();
        _activeIdx[id] = 0;
    }

    /// @notice Number of currently-open loans (length of the sweep set).
    function activeLoanCount() external view returns (uint256) {
        return activeLoanIds.length;
    }

    /// @notice Buy a defaulted loan's collateral outright at the current Dutch floor.
    ///         No router, no DEX, no size limit: the buyer sources liquidity anywhere.
    /// @param maxCost Buyer's protection against a floor move between quote and execution.
    function buyout(uint256 id, uint256 maxCost) external nonReentrant {
        Loan storage L = loans[id];
        if (!L.active) revert NotActive();
        if (block.timestamp <= uint256(L.dueAt) + loanTerms[id].grace) revert NotYetDefaulted();

        L.active = false;
        _removeActive(id);
        _reduceExposure(L.collateral, L.principalUsd18);

        uint256 cost = _settlementFloor(id, L.collAmount);
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
        if (block.timestamp <= uint256(L.dueAt) + loanTerms[id].grace) revert NotYetDefaulted();
        if (!routerAllowed[router]) revert RouterNotAllowed();

        L.active = false;
        _removeActive(id);
        _reduceExposure(L.collateral, L.principalUsd18);

        uint256 proceeds;
        {
            _refreshPrice(L.collateral);
            uint256 bounty = _bountyAmount(L);
            uint256 toSell = L.collAmount - bounty;
            if (bounty > 0) IERC20(L.collateral).safeTransfer(msg.sender, bounty);

            uint256 floor = _settlementFloor(id, toSell);
            if (minOut < floor) minOut = floor;

            proceeds = _swapViaRouter(L.collateral, router, swapData, toSell);
            if (proceeds < minOut) revert BelowFloor();

            // Defense in depth: the router is only ever approved for `toSell` collateral and
            // never for the book's stable, so it cannot pull the reserve buffer. This ceiling
            // additionally rejects a swap that reports far more stable than the sold collateral
            // is worth — the signature of injected funds masking a low sale.
            uint256 p18 = lastPrice18[L.collateral];
            if (p18 != 0) {
                uint256 saneMax = (_usd18ToStable((p18 * toSell) / _unit(L.collateral)) * 15_000) / 10_000;
                if (proceeds > saneMax) revert ProceedsTooHigh();
            }
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

    /// @dev Keeper bounty in collateral: keeperBps of the collateral, USD-capped. Zero when
    ///      the borrower settles their own default (no reward for defaulting) AND zero when the
    ///      loan is underwater — the bounty then comes only out of what would have been the
    ///      borrower's surplus, never ahead of lenders. Underwater defaults are settled via the
    ///      buyout path (arbitrageurs, no bounty) or by a keeper willing to settle for gas alone.
    function _bountyAmount(Loan storage L) internal returns (uint256 b) {
        if (msg.sender == L.borrower || keeperBps == 0) return 0;
        uint256 p18 = lastPrice18[L.collateral];
        if (p18 == 0) return 0;
        uint256 collValueStable = _usd18ToStable((p18 * L.collAmount) / _unit(L.collateral));
        if (collValueStable < L.principal) return 0; // underwater: floor guarantee stays intact
        b = (L.collAmount * keeperBps) / 10_000;
        uint256 capTokens = (uint256(keeperCapUsd18) * _unit(L.collateral)) / p18;
        if (b > capTokens) b = capTokens;
    }

    /// @dev Stable value of `collPortion` at `floorBps` of the oracle price. If FTSO is down:
    ///      reverts inside `oracleFallbackDelay` past due, afterwards decays the cached-price
    ///      floor to zero over ORACLE_DOWN_DECAY so settlement can never be bricked for good.
    function _floorStable(Loan storage L, uint256 collPortion, uint16 floorBps, uint16 floorMinBps)
        internal
        returns (uint256 floor)
    {
        try oracle.usdValue18(L.collateral, collPortion) returns (uint256 v18) {
            _cachePrice(L.collateral, v18, collPortion);
            floor = (_usd18ToStable(v18) * floorBps) / 10_000;
        } catch {
            uint256 fallbackAt = uint256(L.dueAt) + oracleFallbackDelay;
            if (block.timestamp <= fallbackAt) revert OracleDown();
            uint256 p18 = lastPrice18[L.collateral];
            if (p18 == 0) return 0; // no reference ever cached (cannot happen after open)
            uint256 v18 = (p18 * collPortion) / _unit(L.collateral);
            floor = (_usd18ToStable(v18) * floorMinBps) / 10_000;
            // Decay the cached-price floor over the outage, but never below 20% of it: a dead
            // oracle should delay settlement, not hand a sniper the collateral for a pittance.
            // In the absurd tail (oracle dead this long AND price truly below 20%) the loan
            // simply waits for a buyer rather than settling below a sane bound.
            uint256 t = block.timestamp - fallbackAt;
            uint256 floorFloor = floor / 5; // 20%
            floor = t >= ORACLE_DOWN_DECAY ? floorFloor : (floor * (ORACLE_DOWN_DECAY - t)) / ORACLE_DOWN_DECAY;
            if (floor < floorFloor) floor = floorFloor;
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
    /// @dev Snapshot the current owner-set defaults as this loan's fixed terms.
    function _snapshotTerms(uint256 id) internal {
        loanTerms[id] = LoanTerms({
            grace: gracePeriod,
            settleDecayPeriod: settleDecayPeriod,
            settleStartBps: settleStartBps,
            settleFloorMinBps: settleFloorMinBps,
            skimBps: yieldSkimBps
        });
    }

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
