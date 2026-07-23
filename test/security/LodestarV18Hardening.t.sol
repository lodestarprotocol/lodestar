// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {MockERC20, MockFtsoV2, MockRate} from "../Lodestar.t.sol";

/// @notice Regressions for the v1.8 pre-mainnet hardening trio:
///         1) LST rate clamp in the oracle (valuation-side rate limiter vs a compromised provider),
///         2) tier disable (retire a mispriced tier for NEW underwriting without breaking append-only),
///         3) Ownable2Step (a fat-fingered ownership transfer is proposal-only, never final).
contract LodestarV18Hardening is Test {
    MockERC20 usdt0;
    MockERC20 fxrp;
    MockERC20 sflr;
    MockFtsoV2 ftso;
    MockRate sflrRate;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;

    bytes21 constant XRP = bytes21("XRP/USD");
    bytes21 constant FLR = bytes21("FLR/USD");

    address owner = address(this);
    address reserve = makeAddr("reserve");
    address borrower = makeAddr("borrower");

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        fxrp = new MockERC20("FXRP", "FXRP", 6);
        sflr = new MockERC20("sFLR", "sFLR", 18);
        ftso = new MockFtsoV2();
        ftso.set(XRP, 250_000_000, 8); // $2.50
        ftso.set(FLR, 5_000_000, 8); // $0.05

        sflrRate = new MockRate(); // underlyingPerShare = 1e18 initially

        oracle = new LodestarOracle(address(ftso), owner);
        oracle.setFeed(address(fxrp), XRP, address(0), 1 hours, 0);
        oracle.setFeed(address(sflr), FLR, address(sflrRate), 1 hours, 0);

        pool = new LodestarPool(IERC20(address(usdt0)), owner);
        book = new LodestarLoanBook(pool, oracle, reserve, owner);
        pool.setLoanBook(address(book));

        book.addTier(address(fxrp), 5000, 7 days, 200); // tier 0: 50% LTV
        book.addTier(address(fxrp), 7000, 30 days, 200); // tier 1: 70% LTV
        book.addTier(address(sflr), 4500, 7 days, 200); // sFLR tier 0

        usdt0.mint(owner, 500_000e6);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e6, owner);
    }

    function _principal(uint256 id) internal view returns (uint256 p) {
        (,,, p,,,,,,,) = book.loans(id);
    }

    // ------------------------------------------------------------------ 1) rate clamp

    function test_Clamp_UnarmedIsPassthrough() public {
        uint256 base = oracle.priceUsd18(address(sflr)); // $0.05 * 1.0
        sflrRate.set(2e18); // provider doubles the rate
        assertEq(oracle.priceUsd18(address(sflr)), base * 2, "unarmed: raw rate passes through");
    }

    function test_Clamp_BlocksRateSpike() public {
        oracle.setRateClamp(address(sflr), 20); // anchor 1e18, 20 bps/day allowance
        uint256 base = oracle.priceUsd18(address(sflr));
        sflrRate.set(10e18); // compromised provider: 10x overnight
        // zero elapsed time -> allowed == anchor -> price must not move at all
        assertEq(oracle.priceUsd18(address(sflr)), base, "spike fully clamped at t0");
        vm.warp(block.timestamp + 1 days);
        ftso.set(FLR, 5_000_000, 8); // refresh feed ts (staleness bound)
        // one day later: at most +20 bps of valuation, never 10x
        uint256 p = oracle.priceUsd18(address(sflr));
        assertEq(p, (base * 10_020) / 10_000, "one day of allowance only");
    }

    function test_Clamp_OverBorrowBlocked() public {
        oracle.setRateClamp(address(sflr), 20);
        sflrRate.set(10e18); // spiked provider before the victim-loan opens
        sflr.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(sflr), 100_000e18, 0); // $5000 clamped value @45%
        vm.stopPrank();
        // principal reflects the CLAMPED $5,000 valuation (2250e6), not the spiked $50,000 (22500e6)
        assertEq(_principal(id), 2_250e6, "principal underwritten off clamped rate");
    }

    function test_Clamp_AllowsLegitimateGrowth() public {
        oracle.setRateClamp(address(sflr), 20);
        uint256 base = oracle.priceUsd18(address(sflr));
        vm.warp(block.timestamp + 30 days);
        ftso.set(FLR, 5_000_000, 8);
        sflrRate.set(1.005e18); // +0.5% real staking yield over a month (< 20bps/day * 30d = 6%)
        assertEq(oracle.priceUsd18(address(sflr)), (base * 1005) / 1000, "legit growth unclamped");
    }

    function test_Clamp_DecreasePassesThrough() public {
        oracle.setRateClamp(address(sflr), 20);
        uint256 base = oracle.priceUsd18(address(sflr));
        sflrRate.set(0.9e18); // slash: rate DOWN 10%
        assertEq(oracle.priceUsd18(address(sflr)), (base * 9) / 10, "down-moves are never clamped");
    }

    function test_Clamp_PokeRatchetsAtClampedValue() public {
        oracle.setRateClamp(address(sflr), 20);
        sflrRate.set(10e18); // spiked
        vm.warp(block.timestamp + 1 days);
        oracle.pokeRateAnchor(address(sflr));
        // the poke may only advance the anchor along the allowed slope: 1e18 * 1.002
        (uint192 rate,) = oracle.rateAnchors(address(sflr));
        assertEq(uint256(rate), 1.002e18, "anchor ratchets at clamped value, never jumps");
        // UP-ONLY: a poke during a slashed print must NOT bake the low into the anchor…
        sflrRate.set(0.5e18);
        oracle.pokeRateAnchor(address(sflr));
        (rate,) = oracle.rateAnchors(address(sflr));
        assertEq(uint256(rate), 1.002e18, "anchor holds through a down-print (up-only)");
        // …while live valuation still follows the low raw rate immediately (min(raw, allowed))
        ftso.set(FLR, 5_000_000, 8);
        assertEq(oracle.priceUsd18(address(sflr)), (5e16 * 0.5e18) / 1e18, "valuation follows the slash live");
    }

    /// @dev The audit's F1 money path: one poke landing during a transient down-glitch used to
    ///      depress the valuation CEILING for months after recovery (settlement-floor extraction
    ///      on solvent loans). Up-only poke closes it: after recovery, valuation is fully restored.
    function test_Clamp_TransientGlitchPlusPokeCannotDepressCeiling() public {
        oracle.setRateClamp(address(sflr), 20);
        uint256 base = oracle.priceUsd18(address(sflr));
        sflrRate.set(0.5e18); // transient glitch / spoofed low print
        oracle.pokeRateAnchor(address(sflr)); // attacker pokes DURING the glitch
        sflrRate.set(1e18); // provider recovers
        assertEq(oracle.priceUsd18(address(sflr)), base, "ceiling not poisoned by the glitch-poke");
    }

    /// @dev The audit's F2: allowance must not accumulate unbounded between pokes. After 100
    ///      unpoked days a compromised provider harvests at most growth*30d (the window cap),
    ///      never growth*100d.
    function test_Clamp_NeglectedAllowanceIsCapped() public {
        oracle.setRateClamp(address(sflr), 20);
        uint256 base = oracle.priceUsd18(address(sflr));
        vm.warp(block.timestamp + 100 days);
        ftso.set(FLR, 5_000_000, 8);
        sflrRate.set(10e18); // compromise after long poke neglect
        // ceiling = anchor * (1 + 20bps * 30d) = +6%, NOT +20% (100 days of accrual)
        assertEq(oracle.priceUsd18(address(sflr)), (base * 10_600) / 10_000, "instant harvest capped at 30d window");
    }

    /// @dev The audit's F3: re-pointing a feed at a DIFFERENT rate provider must invalidate the
    ///      old anchor (different scale/basis) instead of silently mis-clamping the new provider.
    function test_Clamp_ProviderChangeClearsAnchor() public {
        oracle.setRateClamp(address(sflr), 20);
        MockRate newProvider = new MockRate();
        newProvider.set(5e18); // legitimately different basis
        oracle.setFeed(address(sflr), FLR, address(newProvider), 1 hours, 0);
        (uint192 rate,) = oracle.rateAnchors(address(sflr));
        assertEq(uint256(rate), 0, "anchor cleared on provider change");
        assertEq(oracle.priceUsd18(address(sflr)), (5e16 * 5e18) / 1e18, "new provider unclamped until re-arm");
        // same-provider setFeed (e.g. haircut tweak) must NOT disturb an armed clamp
        oracle.setRateClamp(address(sflr), 20);
        oracle.setFeed(address(sflr), FLR, address(newProvider), 1 hours, 100);
        (rate,) = oracle.rateAnchors(address(sflr));
        assertEq(uint256(rate), 5e18, "same-provider re-set keeps the anchor");
    }

    function test_Clamp_DisarmRestoresRaw() public {
        oracle.setRateClamp(address(sflr), 20);
        sflrRate.set(10e18);
        uint256 clamped = oracle.priceUsd18(address(sflr));
        oracle.setRateClamp(address(sflr), 0); // disarm
        assertGt(oracle.priceUsd18(address(sflr)), clamped * 9, "disarmed: raw 10x rate again");
    }

    function test_Clamp_ParamBounds() public {
        vm.expectRevert(LodestarOracle.BadParam.selector);
        oracle.setRateClamp(address(sflr), 501); // slope above 5%/day defeats the point
        vm.expectRevert(LodestarOracle.BadParam.selector);
        oracle.setRateClamp(address(fxrp), 20); // no rate provider on a 1:1 asset
        vm.expectRevert(LodestarOracle.BadParam.selector);
        oracle.pokeRateAnchor(address(sflr)); // not armed
        vm.expectRevert(LodestarOracle.BadParam.selector);
        oracle.pokeRateAnchor(address(fxrp)); // no provider
    }

    function test_Clamp_RateOfStaysRaw() public {
        // Yield-skim reads rateOf() raw (it has its own +20% clamp, and under-skimming only ever
        // favours the borrower) — the valuation clamp must not leak into it.
        oracle.setRateClamp(address(sflr), 20);
        sflrRate.set(1.1e18);
        assertEq(oracle.rateOf(address(sflr)), 1.1e18, "rateOf unclamped");
        assertLt(oracle.priceUsd18(address(sflr)), (5e16 * 1.1e18) / 1e18, "valuation clamped");
    }

    /// @dev The clamp must never break the money paths under a spiked provider: settlement of a
    ///      defaulted loan (lenders whole first), and the strict lender-exit sweep.
    function test_Clamp_SettlementAndExitsStillWorkUnderSpike() public {
        oracle.setRateClamp(address(sflr), 20);
        // honest loan first: $5000 collateral at 45% -> 2250e6 principal
        sflr.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(sflr), 100_000e18, 0);
        vm.stopPrank();

        // provider compromised AFTER the loan exists, then the loan defaults
        sflrRate.set(10e18);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        ftso.set(FLR, 5_000_000, 8); // fresh feed at the same FLR price

        // buyout at the CLAMPED floor: valuation is ~real (not 10x), so the buyer pays ~real value,
        // lenders are made whole from proceeds, and the pool ends the loan fully unimpaired
        uint256 cost = book.buyoutCost(id);
        // clamped valuation ≈ $5000 (+ ~9 days of 20bps/day allowance ≈ +1.9%), never $50,000
        assertLt(cost, 5_300e6, "buyout priced off clamped value");
        assertGt(cost, 4_000e6, "floor still near real value (Dutch decay from start bps)");
        address buyer = makeAddr("buyer");
        usdt0.mint(buyer, 6_000e6);
        vm.startPrank(buyer);
        usdt0.approve(address(book), type(uint256).max);
        book.buyout(id, cost);
        vm.stopPrank();
        assertEq(pool.impairedLoss(), 0, "settlement true-up cleared all marks");
        assertEq(pool.principalOut(), 0, "principal accounted");

        // lender exit path still live under the spike (sweep prices off the clamped rate)
        uint256 shares = pool.balanceOf(owner) / 10;
        pool.redeem(shares, owner, owner);
    }

    function test_Clamp_LegitJumpIsConservativeNotBreaking() public {
        // A LEGITIMATE sudden rate jump (e.g. a provider migration re-basing the scale) gets clamped
        // until the owner re-arms: borrowing is under-served (conservative), but repay never depends
        // on valuation, so an existing borrower always gets full collateral back.
        sflr.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(sflr), 100_000e18, 0); // principal 2250e6 at rate 1.0
        vm.stopPrank();

        oracle.setRateClamp(address(sflr), 20);
        sflrRate.set(2e18); // legit 2x re-base
        // new borrows are conservative (clamped)…
        sflr.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        uint256 id2 = book.open(address(sflr), 100_000e18, 0);
        assertEq(_principal(id2), 2_250e6, "clamped underwriting until owner re-arms");
        // …but repay of the existing loan is untouched (no valuation on the repay path)
        usdt0.mint(borrower, 5_000e6);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();
        assertEq(sflr.balanceOf(borrower), 100_000e18, "full collateral back");
        // owner re-arms at the new real rate -> full valuation restored immediately
        oracle.setRateClamp(address(sflr), 20);
        (uint192 rate,) = oracle.rateAnchors(address(sflr));
        assertEq(uint256(rate), 2e18, "re-arm re-bases the anchor");
    }

    // ------------------------------------------------------------------ 2) tier disable

    function test_TierDisable_BlocksOpenAndReenable() public {
        book.setTierDisabled(address(fxrp), 0, true);
        fxrp.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        vm.expectRevert(LodestarLoanBook.BadTier.selector);
        book.open(address(fxrp), 1_000e6, 0);
        uint256 id = book.open(address(fxrp), 1_000e6, 1); // other tier unaffected
        vm.stopPrank();
        assertEq(_principal(id), 1_750e6);

        book.setTierDisabled(address(fxrp), 0, false); // re-enable
        fxrp.mint(borrower, 100e6);
        vm.prank(borrower);
        book.open(address(fxrp), 100e6, 0);
    }

    function test_TierDisable_BlocksRollover() public {
        fxrp.mint(borrower, 1_000e6);
        usdt0.mint(borrower, 100e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        usdt0.approve(address(pool), type(uint256).max);
        uint256 id = book.open(address(fxrp), 1_000e6, 0);
        vm.stopPrank();

        book.setTierDisabled(address(fxrp), 1, true);
        vm.prank(borrower);
        vm.expectRevert(LodestarLoanBook.BadTier.selector);
        book.rollover(id, 1); // cannot extend into a retired tier
        vm.prank(borrower);
        book.rollover(id, 0); // enabled tier still rolls fine
    }

    function test_TierDisable_ExistingLoanUnaffected() public {
        fxrp.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(fxrp), 1_000e6, 0);
        vm.stopPrank();

        book.setTierDisabled(address(fxrp), 0, true); // retire the tier the loan was opened at

        usdt0.mint(borrower, 2_000e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.partialRepay(id, 100e6, 0, 0, 0); // pure paydown: no tier read, unaffected
        book.repay(id); // full close unaffected
        vm.stopPrank();
        assertEq(fxrp.balanceOf(borrower), 1_000e6, "collateral returned in full");
    }

    function test_TierDisable_PartialReleaseMayStillTightenAgainstIt() public {
        // partialRepay's tierIndex only ever TIGHTENS the release standard (min with the opening
        // LTV) — referencing a disabled tier there is deliberate, harmless, and stays allowed.
        fxrp.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(fxrp), 1_000e6, 1); // 70% tier: principal 1750e6
        vm.stopPrank();

        book.setTierDisabled(address(fxrp), 0, true); // the stricter 50% tier is retired

        usdt0.mint(borrower, 800e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        // repay 800 -> 950 remains; release 100 XRP; remainder 900 XRP = $2250 * 50% = 1125 >= 950
        book.partialRepay(id, 800e6, 100e6, 0, 0);
        vm.stopPrank();
        assertEq(fxrp.balanceOf(borrower), 100e6, "release validated against the disabled-but-stricter tier");
    }

    function test_TierDisable_IndexBounds() public {
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.setTierDisabled(address(fxrp), 2, true); // out of range
    }

    /// @dev The all-tiers-disabled corner (audit 2.1): an extension-dependent borrower loses the
    ///      rollover path but is NEVER fund-trapped — repay, paydown, release, addCollateral and
    ///      self-buyout all keep working. This is the documented owner-trust trade-off.
    function test_TierDisable_AllDisabledBorrowerEscapes() public {
        fxrp.mint(borrower, 2_000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(fxrp), 1_000e6, 0);
        uint256 id2 = book.open(address(fxrp), 1_000e6, 0);
        vm.stopPrank();

        book.setTierDisabled(address(fxrp), 0, true);
        book.setTierDisabled(address(fxrp), 1, true); // every tier retired

        usdt0.mint(borrower, 4_000e6);
        fxrp.mint(borrower, 1); // one raw unit for the addCollateral probe
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        vm.expectRevert(LodestarLoanBook.BadTier.selector);
        book.rollover(id, 0); // no extension anywhere
        book.partialRepay(id, 100e6, 0, 0, 0); // de-risk still open
        book.addCollateral(id, 1); // cure path still open (1 raw unit)
        book.repay(id); // full exit still open
        vm.stopPrank();

        // and a defaulted loan can still self-settle via buyout (no bounty for self-settle)
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        ftso.set(XRP, 250_000_000, 8);
        uint256 cost = book.buyoutCost(id2);
        vm.startPrank(borrower);
        usdt0.approve(address(book), type(uint256).max);
        book.buyout(id2, cost);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ 3) Ownable2Step

    function test_TwoStep_TransferIsProposalOnly() public {
        address safe = makeAddr("safe");
        book.transferOwnership(safe);
        oracle.transferOwnership(safe);
        pool.transferOwnership(safe);
        // proposal does NOT change the owner — a typo'd address can no longer brick ownership
        assertEq(book.owner(), owner);
        assertEq(oracle.owner(), owner);
        assertEq(pool.owner(), owner);
        assertEq(book.pendingOwner(), safe);

        vm.startPrank(safe);
        book.acceptOwnership();
        oracle.acceptOwnership();
        pool.acceptOwnership();
        vm.stopPrank();
        assertEq(book.owner(), safe);
        assertEq(oracle.owner(), safe);
        assertEq(pool.owner(), safe);
    }

    function test_TwoStep_OnlyPendingCanAccept() public {
        address safe = makeAddr("safe");
        address mallory = makeAddr("mallory");
        book.transferOwnership(safe);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        book.acceptOwnership();
        // and the current owner can overwrite a wrong proposal before it is ever accepted
        book.transferOwnership(owner);
        assertEq(book.pendingOwner(), owner);
    }

    function test_TwoStep_AcceptClearsPending_AndCancelWorks() public {
        address safe = makeAddr("safe");
        book.transferOwnership(safe);
        vm.prank(safe);
        book.acceptOwnership();
        assertEq(book.pendingOwner(), address(0), "pending cleared after accept (runbook 5b check)");
        // cancel path: proposing address(0) voids an outstanding proposal
        vm.startPrank(safe);
        book.transferOwnership(owner);
        book.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(book.pendingOwner(), address(0), "proposal cancelled");
        assertEq(book.owner(), safe, "owner unchanged by cancel");
    }
}
