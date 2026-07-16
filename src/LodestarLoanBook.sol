// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LodestarOracle} from "./LodestarOracle.sol";
import {LodestarPool} from "./LodestarPool.sol";
import {IDexRouter} from "./interfaces/IDexRouter.sol";

/// @title LodestarLoanBook
/// @notice Fixed-term, no-liquidation loans on Flare. Lock yield-bearing collateral
///         (FXRP, sFLR), receive USDT0 at a tier LTV, repay by a deadline. Price crashes
///         never liquidate you — only the calendar can. On default a keeper settles the
///         loan behind an FTSO-anchored price floor; lenders are made whole first and any
///         surplus (incl. accrued collateral yield) returns to the borrower.
contract LodestarLoanBook is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Tier {
        uint16 ltvBps; // loan-to-value in bps
        uint32 duration; // seconds
        uint16 feeBps; // one-time fee in bps of principal
    }

    struct Loan {
        address borrower;
        address collateral;
        uint256 collAmount;
        uint256 principal; // stable owed (excl. fee)
        uint256 fee; // one-time stable fee
        uint256 principalUsd18; // usd18 principal recorded at open (for exposure accounting)
        uint64 openedAt;
        uint64 dueAt;
        bool active;
    }

    // --- immutable wiring ---
    LodestarPool public immutable pool;
    LodestarOracle public immutable oracle;
    IERC20 public immutable stable;
    uint8 public immutable stableDecimals;
    uint256 public immutable stableUnit; // 10**stableDecimals, cached to avoid EXP in the hot path

    // --- params (owner-set; intended to sit behind a timelock/multisig in prod) ---
    address public reserve;
    IDexRouter public router;
    uint64 public gracePeriod = 48 hours;
    uint16 public keeperBps = 500; // 5% of collateral to the settling keeper
    uint16 public penaltyBps = 500; // 5% of principal to reserve on default
    uint16 public feeReserveBps = 2000; // 20% of every fee to reserve, remainder to lenders
    uint16 public settleFloorBps = 9800; // keeper swap must clear >= 98% of FTSO value
    uint32 public maxLoanLife = 90 days;
    uint64 public oracleFallbackDelay = 7 days; // once this far past due, a defaulted loan can settle even if FTSO is down
    bool public paused; // when true, blocks NEW borrows only; repay/rollover/settle stay open (non-custodial)

    mapping(address => Tier[]) public tiers; // per-collateral tiers
    mapping(address => uint256) public exposureUsd18; // outstanding principal per collateral (usd18)
    mapping(address => uint256) public exposureCapUsd18; // 0 = uncapped
    mapping(uint256 => Loan) public loans;
    uint256 public nextLoanId = 1;

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
    event LoanSettled(uint256 indexed id, address indexed keeper, uint256 proceeds, uint256 surplus, bool shortfall);
    event TierAdded(address indexed collateral, uint16 ltvBps, uint32 duration, uint16 feeBps);

    error NotSupported();
    error BadTier();
    error CapExceeded();
    error NotActive();
    error NotYetDefaulted();
    error Expired();
    error BadParam();
    error Paused();
    error OracleDown();

    constructor(LodestarPool _pool, LodestarOracle _oracle, address _reserve, address _owner) Ownable(_owner) {
        if (_reserve == address(0)) revert BadParam();
        pool = _pool;
        oracle = _oracle;
        stable = IERC20(_pool.asset());
        stableDecimals = IERC20Metadata(_pool.asset()).decimals();
        stableUnit = 10 ** stableDecimals;
        reserve = _reserve;
    }

    // ------------------------------------------------------------------ admin
    function addTier(address collateral, uint16 ltvBps, uint32 duration, uint16 feeBps) external onlyOwner {
        if (ltvBps > 9000 || feeBps > 2000 || duration == 0 || duration > maxLoanLife) revert BadParam();
        tiers[collateral].push(Tier(ltvBps, duration, feeBps));
        emit TierAdded(collateral, ltvBps, duration, feeBps);
    }

    function setExposureCap(address collateral, uint256 capUsd18) external onlyOwner {
        exposureCapUsd18[collateral] = capUsd18;
    }

    function setRouter(IDexRouter _router) external onlyOwner {
        router = _router;
    }

    function setReserve(address _reserve) external onlyOwner {
        if (_reserve == address(0)) revert BadParam();
        reserve = _reserve;
    }

    function setRiskParams(uint64 grace, uint16 keeper_, uint16 penalty_, uint16 feeReserve_) external onlyOwner {
        if (keeper_ > 2000 || penalty_ > 2000 || feeReserve_ > 10_000 || grace > 14 days) revert BadParam();
        gracePeriod = grace;
        keeperBps = keeper_;
        penaltyBps = penalty_;
        feeReserveBps = feeReserve_;
    }

    /// @notice Minimum fraction of FTSO value a keeper's settlement swap must return (bps).
    function setSettleFloorBps(uint16 bps) external onlyOwner {
        if (bps < 5000 || bps > 10_000) revert BadParam();
        settleFloorBps = bps;
    }

    /// @notice Pause new borrows in an emergency. Existing loans, repay, and settlement are unaffected.
    function setPaused(bool p) external onlyOwner {
        paused = p;
    }

    /// @notice How long past a deadline a loan can settle without a working oracle (bounded).
    function setOracleFallbackDelay(uint64 d) external onlyOwner {
        if (d < 1 days || d > 30 days) revert BadParam();
        oracleFallbackDelay = d;
    }

    // ------------------------------------------------------------------ views
    function tierCount(address collateral) external view returns (uint256) {
        return tiers[collateral].length;
    }

    function isDefaulted(uint256 id) public view returns (bool) {
        Loan memory l = loans[id];
        return l.active && block.timestamp > uint256(l.dueAt) + gracePeriod;
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
        uint256 balBefore = IERC20(collateral).balanceOf(address(this));
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), collAmount);
        collAmount = IERC20(collateral).balanceOf(address(this)) - balBefore;
        if (collAmount == 0) revert BadParam();

        uint256 valueUsd18 = oracle.usdValue18(collateral, collAmount);
        uint256 principalUsd18 = (valueUsd18 * t.ltvBps) / 10_000;

        uint256 cap = exposureCapUsd18[collateral];
        if (cap != 0 && exposureUsd18[collateral] + principalUsd18 > cap) revert CapExceeded();
        exposureUsd18[collateral] += principalUsd18;

        uint256 principal = _usd18ToStable(principalUsd18);
        if (principal == 0) revert BadParam(); // reject dust loans
        uint256 fee = (principal * t.feeBps) / 10_000;

        id = nextLoanId++;
        uint64 dueAt = uint64(block.timestamp + t.duration);
        loans[id] = Loan({
            borrower: msg.sender,
            collateral: collateral,
            collAmount: collAmount,
            principal: principal,
            fee: fee,
            principalUsd18: principalUsd18,
            openedAt: uint64(block.timestamp),
            dueAt: dueAt,
            active: true
        });

        pool.disburse(msg.sender, principal);
        emit LoanOpened(id, msg.sender, collateral, collAmount, principal, fee, dueAt);
    }

    /// @notice Repay principal + fee and reclaim collateral (incl. any yield the LST accrued).
    function repay(uint256 id) external nonReentrant {
        Loan storage L = loans[id];
        if (!L.active) revert NotActive();

        uint256 principal = L.principal;
        uint256 fee = L.fee;

        L.active = false;
        _reduceExposure(L.collateral, L.principalUsd18);

        // pull principal + fee into the pool, route reserve cut of the fee back out
        pool.pull(msg.sender, principal + fee);
        pool.onPrincipalReturned(principal);
        uint256 rcut = (fee * feeReserveBps) / 10_000;
        if (rcut > 0) pool.payout(reserve, rcut);

        IERC20(L.collateral).safeTransfer(L.borrower, L.collAmount);
        emit LoanRepaid(id, msg.sender);
    }

    /// @notice Extend a loan before its deadline by paying another tier fee (up to maxLoanLife).
    function rollover(uint256 id, uint256 tierIndex) external nonReentrant {
        Loan storage L = loans[id];
        if (!L.active) revert NotActive();
        if (block.timestamp > L.dueAt) revert Expired();
        Tier[] storage ts = tiers[L.collateral];
        if (tierIndex >= ts.length) revert BadTier();

        uint256 addFee = (L.principal * ts[tierIndex].feeBps) / 10_000;
        uint64 newDue = uint64(block.timestamp + ts[tierIndex].duration);
        if (newDue > uint64(L.openedAt) + maxLoanLife) revert Expired();

        pool.pull(msg.sender, addFee);
        uint256 rcut = (addFee * feeReserveBps) / 10_000;
        if (rcut > 0) pool.payout(reserve, rcut);

        L.dueAt = newDue;
        emit LoanRolled(id, newDue, addFee);
    }

    /// @notice Permissionless settlement of a defaulted loan (deadline + grace elapsed).
    /// @param minOut Keeper's own min-out; the effective floor is max(minOut, settleFloorBps of FTSO value).
    function settle(uint256 id, uint256 minOut) external nonReentrant {
        Loan storage L = loans[id];
        if (!L.active) revert NotActive();
        if (block.timestamp <= uint256(L.dueAt) + gracePeriod) revert NotYetDefaulted();

        L.active = false;
        _reduceExposure(L.collateral, L.principalUsd18);

        uint256 proceeds = _liquidateCollateral(L, minOut);
        (uint256 surplus, bool shortfall) = _distribute(L, proceeds);
        emit LoanSettled(id, msg.sender, proceeds, surplus, shortfall);
    }

    /// @dev Pays the keeper bounty in-kind and swaps the rest to stable behind an FTSO floor.
    function _liquidateCollateral(Loan storage L, uint256 minOut) internal returns (uint256 proceeds) {
        uint256 bounty = (L.collAmount * keeperBps) / 10_000;
        uint256 toSell = L.collAmount - bounty;
        IERC20(L.collateral).safeTransfer(msg.sender, bounty);

        // FTSO-anchored floor. If the oracle is unavailable, only allow a floor bypass once well past
        // due (oracleFallbackDelay) so a transient outage can never be used to underprice a settlement.
        uint256 floor;
        try oracle.usdValue18(L.collateral, toSell) returns (uint256 v) {
            floor = (_usd18ToStable(v) * settleFloorBps) / 10_000;
        } catch {
            if (block.timestamp <= uint256(L.dueAt) + oracleFallbackDelay) revert OracleDown();
            floor = 0; // keeper's own minOut becomes the only bound
        }
        uint256 minOutEff = minOut > floor ? minOut : floor;

        IERC20(L.collateral).forceApprove(address(router), toSell);
        address[] memory path = new address[](2);
        path[0] = L.collateral;
        path[1] = address(stable);
        uint256 balBefore = stable.balanceOf(address(this));
        router.swapExactTokensForTokens(toSell, minOutEff, path, address(this), block.timestamp);
        IERC20(L.collateral).forceApprove(address(router), 0); // clear any residual allowance
        proceeds = stable.balanceOf(address(this)) - balBefore;
    }

    /// @dev Waterfall: principal -> fee (net of reserve cut) -> penalty -> surplus to borrower.
    function _distribute(Loan storage L, uint256 proceeds) internal returns (uint256 remaining, bool shortfall) {
        remaining = proceeds;

        uint256 payPrincipal = remaining >= L.principal ? L.principal : remaining;
        remaining -= payPrincipal;
        stable.safeTransfer(address(pool), payPrincipal);
        pool.onPrincipalReturned(L.principal); // full principal cleared; any shortfall is a realized lender loss
        shortfall = payPrincipal < L.principal;

        uint256 payFee = remaining >= L.fee ? L.fee : remaining;
        remaining -= payFee;
        if (payFee > 0) {
            uint256 rcut = (payFee * feeReserveBps) / 10_000;
            stable.safeTransfer(address(pool), payFee - rcut);
            if (rcut > 0) stable.safeTransfer(reserve, rcut);
        }

        uint256 penalty = (L.principal * penaltyBps) / 10_000;
        uint256 payPenalty = remaining >= penalty ? penalty : remaining;
        remaining -= payPenalty;
        if (payPenalty > 0) stable.safeTransfer(reserve, payPenalty);

        if (remaining > 0) stable.safeTransfer(L.borrower, remaining);
    }

    // ------------------------------------------------------------------ internal
    function _reduceExposure(address collateral, uint256 principalUsd18) internal {
        uint256 e = exposureUsd18[collateral];
        exposureUsd18[collateral] = principalUsd18 >= e ? 0 : e - principalUsd18;
    }

    function _usd18ToStable(uint256 usd18) internal view returns (uint256) {
        return (usd18 * stableUnit) / 1e18;
    }
}
