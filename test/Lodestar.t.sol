// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LodestarOracle} from "../src/LodestarOracle.sol";
import {LodestarPool} from "../src/LodestarPool.sol";
import {LodestarLoanBook} from "../src/LodestarLoanBook.sol";
import {IFtsoV2} from "../src/interfaces/IFtsoV2.sol";
import {IDexRouter} from "../src/interfaces/IDexRouter.sol";
import {ILstRateProvider} from "../src/interfaces/ILstRateProvider.sol";

// ------------------------------------------------------------------ mocks
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockFtsoV2 is IFtsoV2 {
    mapping(bytes21 => uint256) public value;
    mapping(bytes21 => int8) public dec;

    function set(bytes21 id, uint256 v, int8 d) external {
        value[id] = v;
        dec[id] = d;
    }

    function getFeedById(bytes21 id) external view returns (uint256, int8, uint64) {
        return (value[id], dec[id], uint64(block.timestamp));
    }
}

contract MockRouter is IDexRouter {
    uint256 public num = 1;
    uint256 public den = 1;

    function setRate(uint256 _num, uint256 _den) external {
        num = _num;
        den = _den;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * num) / den;
        require(out >= amountOutMin, "MockRouter: slippage");
        IERC20(path[1]).transfer(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

/// @dev Router that takes less than the requested amount — must trip SwapIncomplete.
contract SkimmingRouter {
    function swapExactTokensForTokens(uint256 amountIn, uint256, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn / 2); // takes only half
        IERC20(path[1]).transfer(to, 1);
        amounts = new uint256[](2);
    }
}

contract MockRate is ILstRateProvider {
    uint256 public rate = 1e18;

    function set(uint256 r) external {
        rate = r;
    }

    function underlyingPerShare() external view returns (uint256) {
        return rate;
    }
}

// ------------------------------------------------------------------ tests
contract LodestarTest is Test {
    MockERC20 usdt0; // 6dp stable
    MockERC20 fxrp; // 6dp collateral (XRP)
    MockERC20 sflr; // 18dp collateral (LST)
    MockFtsoV2 ftso;
    MockRouter router;
    MockRate sflrRate;
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;

    address owner = address(this);
    address reserve = address(0xEE5E);
    address lender = address(0x1E7D);
    address borrower = address(0xB0B);
    address keeper = address(0xC0FFEE);
    address buyer = address(0xB1D);

    bytes21 constant XRP_USD = bytes21("XRP/USD");
    bytes21 constant FLR_USD = bytes21("FLR/USD");

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        fxrp = new MockERC20("FXRP", "FXRP", 6);
        sflr = new MockERC20("Staked FLR", "sFLR", 18);

        ftso = new MockFtsoV2();
        ftso.set(XRP_USD, 250_000_000, 8); // $2.50
        ftso.set(FLR_USD, 2_000_000, 8); // $0.02

        sflrRate = new MockRate(); // 1 sFLR = 1 FLR initially

        oracle = new LodestarOracle(address(ftso), owner);
        oracle.setFeed(address(fxrp), XRP_USD, address(0), 1 hours);
        oracle.setFeed(address(sflr), FLR_USD, address(sflrRate), 1 hours);

        pool = new LodestarPool(IERC20(address(usdt0)), owner);
        book = new LodestarLoanBook(pool, oracle, reserve, owner);
        pool.setLoanBook(address(book));

        router = new MockRouter();
        book.setRouterAllowed(address(router), true);

        // FXRP tier: 50% LTV, 7d, 2% fee. sFLR tier: 55% LTV, 30d, 3% fee (calibrated v1.3).
        book.addTier(address(fxrp), 5000, 7 days, 200);
        book.addTier(address(sflr), 5500, 30 days, 300);

        // seed lender pool with 100k USDT0
        usdt0.mint(lender, 100_000e6);
        vm.startPrank(lender);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(100_000e6, lender);
        vm.stopPrank();

        // router liquidity for settlement swaps
        usdt0.mint(address(router), 1_000_000e6);
    }

    // ------------------------------------------------------------------ helpers
    function _openFxrp(address who, uint256 coll) internal returns (uint256 id) {
        fxrp.mint(who, coll);
        vm.startPrank(who);
        fxrp.approve(address(book), type(uint256).max);
        id = book.open(address(fxrp), coll, 0);
        vm.stopPrank();
    }

    function _swapData(uint256 amountIn) internal view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = address(fxrp);
        path[1] = address(usdt0);
        return abi.encodeCall(MockRouter.swapExactTokensForTokens, (amountIn, 0, path, address(book), block.timestamp));
    }

    function _principal(uint256 id) internal view returns (uint256 p) {
        (,,, p,,,,,,,) = book.loans(id);
    }

    // ------------------------------------------------------------------ core flows
    function test_OpenAndRepay_FeeNettedAtOpen() public {
        uint256 assetsBefore = pool.totalAssets();

        // 1000 FXRP @ $2.50 = $2500, 50% LTV -> principal 1250, 2% fee = 25 netted from disbursement
        uint256 id = _openFxrp(borrower, 1000e6);
        assertEq(usdt0.balanceOf(borrower), 1225e6, "borrower receives principal minus fee");
        assertEq(pool.principalOut(), 1250e6, "full principal owed back");
        // fee earned instantly: 80% of 25 to lenders, 20% (5) into the first-loss buffer
        assertEq(book.reserveBalance(), 5e6, "reserve cut buffered");
        assertEq(usdt0.balanceOf(address(book)), 5e6, "book holds exactly the buffer");
        assertApproxEqAbs(pool.totalAssets(), assetsBefore + 20e6, 1, "lender yield accrued at open");

        // repay is principal-only now
        usdt0.mint(borrower, 25e6); // top up the netted fee to cover full principal
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();

        assertEq(fxrp.balanceOf(borrower), 1000e6, "collateral returned");
        assertEq(pool.principalOut(), 0, "principal cleared");
        assertApproxEqAbs(pool.totalAssets(), assetsBefore + 20e6, 1, "yield preserved through repay");
    }

    function test_NoLiquidationOnPriceCrash() public {
        uint256 id = _openFxrp(borrower, 1000e6);

        // XRP crashes 60% -> collateral now worth $1000 < debt. Traditional lender would liquidate.
        ftso.set(XRP_USD, 100_000_000, 8); // $1.00

        // Lodestar: cannot be settled while inside the term, no matter the price.
        vm.expectRevert(LodestarLoanBook.NotYetDefaulted.selector);
        book.buyout(id, type(uint256).max);
        vm.expectRevert(LodestarLoanBook.NotYetDefaulted.selector);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
        assertFalse(book.isDefaulted(id), "not defaulted mid-term");
    }

    function test_DefaultSettlementViaSwap() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        router.setRate(25, 10); // router pays $2.50 per FXRP, matching FTSO

        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        assertTrue(book.isDefaulted(id), "defaulted");

        uint256 poolBefore = pool.totalAssets();
        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(950e6), 0);

        // keeper got 5% of 1000 FXRP in-kind ($125 < $500 cap, so uncapped here)
        assertEq(fxrp.balanceOf(keeper), 50e6, "keeper bounty in-kind");
        assertEq(pool.principalOut(), 0, "principal cleared");
        assertGe(pool.totalAssets(), poolBefore, "lenders made whole");
        // borrower received surplus above principal + penalty
        assertGt(usdt0.balanceOf(borrower), 1225e6, "surplus returned to borrower");
    }

    function test_DefaultSettlementViaBuyout() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);

        uint256 cost = book.buyoutCost(id); // ~100% of $2500 right after default
        assertApproxEqRel(cost, 2500e6, 0.01e18, "buyout cost near full FTSO value at default");

        usdt0.mint(buyer, cost);
        uint256 poolBefore = pool.totalAssets();
        vm.startPrank(buyer);
        usdt0.approve(address(book), cost);
        book.buyout(id, cost);
        vm.stopPrank();

        assertEq(fxrp.balanceOf(buyer), 1000e6, "buyer received all collateral");
        assertEq(pool.principalOut(), 0, "principal cleared");
        assertGe(pool.totalAssets(), poolBefore, "lenders made whole");
        assertGt(usdt0.balanceOf(borrower), 1225e6, "surplus returned to borrower");
    }

    function test_DutchFloorDecays() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        router.setRate(225, 100); // router pays $2.25 = 90% of FTSO value

        // right after default the floor is ~100%: a 90% fill must fail
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        assertEq(book.currentFloorBps(id), 10_000, "floor starts at 100%");
        vm.prank(keeper);
        vm.expectRevert(LodestarLoanBook.BelowFloor.selector);
        book.settleSwap(id, address(router), _swapData(950e6), 0);

        // after the full decay period the floor is 85%: the same 90% fill clears
        vm.warp(block.timestamp + 24 hours);
        assertEq(book.currentFloorBps(id), 8_500, "floor decayed to min");
        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
        assertEq(pool.principalOut(), 0, "settled at the decayed floor");
    }

    function test_BuyoutByBorrowerIsAllowed() public {
        // A borrower buying out their own default is just late repayment at market price.
        uint256 id = _openFxrp(borrower, 1000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        uint256 cost = book.buyoutCost(id);
        usdt0.mint(borrower, cost);
        vm.startPrank(borrower);
        usdt0.approve(address(book), cost);
        book.buyout(id, cost);
        vm.stopPrank();
        assertEq(fxrp.balanceOf(borrower), 1000e6, "borrower reclaimed collateral");
    }

    function test_SelfSettleEarnsNoBounty() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        router.setRate(25, 10);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);

        vm.prank(borrower);
        book.settleSwap(id, address(router), _swapData(1000e6), 0); // full amount: no bounty carve-out
        assertEq(fxrp.balanceOf(borrower), 0, "no bounty for settling your own default");
    }

    function test_KeeperBountyUsdCapped() public {
        // 100k FXRP @ $2.50 = $250k collateral. 5% = 5000 FXRP ($12.5k) must cap at $500 = 200 FXRP.
        usdt0.mint(lender, 200_000e6);
        vm.startPrank(lender);
        pool.deposit(200_000e6, lender);
        vm.stopPrank();

        uint256 id = _openFxrp(borrower, 100_000e6);
        router.setRate(25, 10);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);

        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(100_000e6 - 200e6), 0);
        assertEq(fxrp.balanceOf(keeper), 200e6, "bounty capped at $500 of collateral");
    }

    function test_RolloverRequiresHealth_AddCollateralCures() public {
        uint256 id = _openFxrp(borrower, 1000e6);

        // price drops 40%: at $1.50 the position no longer qualifies at 50% LTV
        ftso.set(XRP_USD, 150_000_000, 8);
        usdt0.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        vm.expectRevert(LodestarLoanBook.Undercollateralized.selector);
        book.rollover(id, 0);

        // cure: top up collateral until the tier LTV holds again, then roll
        fxrp.mint(borrower, 700e6);
        book.addCollateral(id, 700e6); // 1700 FXRP * $1.50 * 50% = $1275 >= $1250
        book.rollover(id, 0);
        vm.stopPrank();

        (,,,,,,, uint64 dueAt,,,) = book.loans(id);
        assertEq(uint256(dueAt), block.timestamp + 7 days, "extended after cure");
    }

    function test_RolloverFineWhenHealthy() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        usdt0.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.rollover(id, 0);
        vm.stopPrank();
        assertEq(book.reserveBalance(), 5e6 + 5e6, "open + rollover reserve cuts buffered");
    }

    function test_ImpairMarksLossImmediately_RepayReverses() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);

        // crash to $0.50: collateral $500 vs principal 1250
        ftso.set(XRP_USD, 50_000_000, 8);
        uint256 assetsBefore = pool.totalAssets();
        book.impair(id);
        // expected recovery = 500 * 95% = 475; marked loss = 1250 - 475 = 775
        assertEq(pool.impairedLoss(), 775e6, "expected loss marked");
        assertEq(pool.totalAssets(), assetsBefore - 775e6, "share price marked down at default");

        // late repay reverses the mark completely
        usdt0.mint(borrower, 1250e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();
        assertEq(pool.impairedLoss(), 0, "mark reversed on repay");
        assertEq(pool.totalAssets(), assetsBefore, "pool restored");
    }

    function test_ExtremeCrashMidTerm_ImpairTracksAndReverses() public {
        // the "80% in one day" scenario: crash on day 2 of a 7-day term
        uint256 id = _openFxrp(borrower, 1000e6);
        vm.warp(block.timestamp + 2 days);
        ftso.set(XRP_USD, 50_000_000, 8); // $2.50 -> $0.50

        uint256 assetsBefore = pool.totalAssets();
        book.impair(id); // permissionless, mid-term
        // expected recovery 500 * 95% = 475 vs principal 1250 -> 775 marked instantly
        assertEq(pool.impairedLoss(), 775e6, "mid-term loss not marked");
        assertEq(pool.totalAssets(), assetsBefore - 775e6, "share price not marked down");

        // the loan itself is untouched: no liquidation, borrower keeps full optionality
        (,,,,,,,, bool active,,) = book.loans(id);
        assertTrue(active);
        assertEq(fxrp.balanceOf(address(book)), 1000e6, "collateral moved on impair");

        // price recovers before the deadline: anyone re-marks to zero, then normal repay
        ftso.set(XRP_USD, 250_000_000, 8);
        book.impair(id);
        assertEq(pool.impairedLoss(), 0, "recovery not reversed");
        usdt0.mint(borrower, 25e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();
        assertEq(pool.totalAssets(), assetsBefore, "pool not restored after recovery + repay");
        assertEq(fxrp.balanceOf(borrower), 1000e6, "borrower collateral back");
    }

    // ---- v1.3.2 hardening regressions (from the 3-agent adversarial audit) ----

    function test_ImpairWorksWhileOracleStalled() public {
        // agent-1 MED: impair must still mark during an FTSO outage (exactly when a crash hits)
        uint256 id = _openFxrp(borrower, 1000e6); // caches $2.50
        vm.warp(block.timestamp + 2 days);
        ftso.set(XRP_USD, 0, 8); // FTSO down -> usdValue18 reverts
        book.impair(id); // must fall back to the cached $2.50, not revert
        // cached value 2500 * 95% = 2375 >= principal 1250 -> healthy at cache, marks 0
        assertEq(pool.impairedLoss(), 0, "cache fallback mismark");
        // now a loan that IS underwater at the cached price still marks via fallback
    }

    function test_ImpairHealthyOraclePathCaches() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        vm.warp(block.timestamp + 2 days);
        ftso.set(XRP_USD, 250_000_000, 8); // healthy: $2.50, coll $2500 > principal 1250
        book.impair(id);
        assertEq(pool.impairedLoss(), 0, "healthy loan marked a loss");
        assertGt(book.lastPrice18(address(fxrp)), 0, "price not cached");
    }

    function test_UnderwaterSettleSwapPaysNoBounty() public {
        // agent-2 MED: on an underwater loan the keeper bounty must not come ahead of lenders
        uint256 id = _openFxrp(borrower, 1000e6); // $2500 coll, $1250 principal
        ftso.set(XRP_USD, 100_000_000, 8); // $1.00 -> coll $1000 < principal 1250 (underwater)
        router.setRate(10, 10); // router pays $1.00/FXRP
        vm.warp(block.timestamp + 7 days + 48 hours + 24 hours + 1); // full decay -> 85% floor

        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(1000e6), 0); // sells FULL amount, no carve
        assertEq(fxrp.balanceOf(keeper), 0, "keeper took a bounty on an underwater loan");
        assertEq(pool.principalOut(), 0, "not settled");
    }

    function test_HealthySettleSwapStillPaysBounty() public {
        uint256 id = _openFxrp(borrower, 1000e6); // healthy: $2500 vs $1250
        router.setRate(25, 10);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
        assertEq(fxrp.balanceOf(keeper), 50e6, "healthy-loan bounty missing");
    }

    function test_ProceedsCeilingRejectsInjection() public {
        // agent-1 HIGH (disproven as a drain, kept as defense in depth): a router reporting
        // wildly more stable than the collateral is worth is rejected.
        uint256 id = _openFxrp(borrower, 1000e6);
        router.setRate(50, 10); // pays $5.00/FXRP = 2x oracle -> above the 1.5x sane ceiling
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        vm.prank(keeper);
        vm.expectRevert(LodestarLoanBook.ProceedsTooHigh.selector);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
    }

    function test_YieldSkimClampedOnAbnormalRate() public {
        book.setYieldSkimBps(5000);
        sflr.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(sflr), 100_000e18, 0);
        vm.stopPrank();

        sflrRate.set(5e18); // absurd 5x rate spike (manipulated provider)
        usdt0.mint(borrower, 40e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();

        // skim is clamped to a 20%-appreciation basis, not 5x -> borrower keeps the vast majority
        uint256 cappedRate = uint256(1e18) * 12000 / 10000; // 1.2e18
        uint256 gain = (100_000e18 * (cappedRate - 1e18)) / cappedRate;
        uint256 maxSkim = (gain * 5000) / 10_000;
        assertLe(sflr.balanceOf(reserve), maxSkim, "skim not clamped");
        assertGt(sflr.balanceOf(borrower), 90_000e18, "borrower over-skimmed");
    }

    function test_OracleScaledZeroReverts() public {
        // a feed whose decimals floor the scaled price to zero must revert, not return 0
        ftso.set(XRP_USD, 5, 30); // value 5 at 30 decimals -> 5 / 10^12 == 0 when scaled to 1e18
        vm.expectRevert(LodestarOracle.BadPrice.selector);
        oracle.priceUsd18(address(fxrp));
    }

    function test_ImpairHealthyLoanIsNoOp() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        uint256 assetsBefore = pool.totalAssets();
        book.impair(id);
        assertEq(pool.impairedLoss(), 0, "healthy loan marked");
        assertEq(pool.totalAssets(), assetsBefore, "share price moved on healthy impair");
    }

    function test_ImpairTruedUpAtSettlement_ReserveCoversFirst() public {
        // build a reserve buffer with a fee-paying loan first
        uint256 id0 = _openFxrp(address(0xFEE), 1000e6);
        usdt0.mint(address(0xFEE), 1250e6);
        vm.startPrank(address(0xFEE));
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id0);
        vm.stopPrank();
        assertEq(book.reserveBalance(), 5e6, "buffer funded");

        uint256 id = _openFxrp(borrower, 1000e6); // second open adds another 5 to the buffer
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        ftso.set(XRP_USD, 50_000_000, 8); // deep crash
        book.impair(id);

        router.setRate(5, 10); // router pays the crashed $0.50
        uint256 assetsBefore = pool.totalAssets(); // already marked down by 775
        vm.prank(keeper);
        // underwater -> no keeper bounty, so the FULL 1000 FXRP is sold
        book.settleSwap(id, address(router), _swapData(1000e6), 0);

        // proceeds 500 (1000 FXRP * $0.50) -> shortfall 750, buffer covers 10, loss realized 740
        assertEq(pool.impairedLoss(), 0, "impairment cleared at settlement");
        assertEq(book.reserveBalance(), 0, "buffer used as first loss");
        // mark estimated 475 recovery; settlement realized 500 + 10 cover = 510: pool lands 35
        // above the marked level - a conservative mark, never a downward cliff on lenders
        assertEq(pool.totalAssets(), assetsBefore + 35e6, "settlement cliff");
        assertEq(pool.principalOut(), 0);
    }

    function test_sFLRYieldStaysWithBorrower() public {
        // 100k sFLR (@ $0.02 = $2000), 55% LTV -> principal 1100, 3% fee = 33
        sflr.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(sflr), 100_000e18, 0);
        vm.stopPrank();
        assertEq(usdt0.balanceOf(borrower), 1100e6 - 33e6, "principal minus fee @55% LTV");

        // while locked, sFLR appreciates 10% vs FLR (staking yield)
        sflrRate.set(1.1e18);

        usdt0.mint(borrower, 33e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();
        assertEq(sflr.balanceOf(borrower), 100_000e18, "full yield-bearing collateral returned");
    }

    function test_YieldSkimRoutesAppreciationToReserve() public {
        book.setYieldSkimBps(5000);
        sflr.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(sflr), 100_000e18, 0);
        vm.stopPrank();

        sflrRate.set(1.1e18);

        usdt0.mint(borrower, 40e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();

        uint256 gain = (100_000e18 * (1.1e18 - 1e18)) / uint256(1.1e18);
        uint256 expectedSkim = (gain * 5000) / 10_000;
        assertEq(sflr.balanceOf(reserve), expectedSkim, "wrong skim to reserve");
        assertEq(sflr.balanceOf(borrower) + expectedSkim, 100_000e18, "collateral tokens not conserved");
    }

    // ------------------------------------------------------------------ guards
    function test_RejectsDustLoan() public {
        sflr.mint(borrower, 1e9);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.open(address(sflr), 1e9, 0);
        vm.stopPrank();
    }

    function test_MinPrincipalEnforced() public {
        // default minPrincipal = 10 USDT0; 15 FXRP @ $2.50 * 50% = $18.75 passes, 7 FXRP = $8.75 fails
        fxrp.mint(borrower, 22e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.open(address(fxrp), 7e6, 0);
        book.open(address(fxrp), 15e6, 0); // fine
        vm.stopPrank();
    }

    function test_RouterMustBeWhitelisted() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        MockRouter rogue = new MockRouter();
        usdt0.mint(address(rogue), 10_000e6);
        vm.prank(keeper);
        vm.expectRevert(LodestarLoanBook.RouterNotAllowed.selector);
        book.settleSwap(id, address(rogue), _swapData(950e6), 0);
    }

    function test_SwapMustTakeExactSaleAmount() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        SkimmingRouter skim = new SkimmingRouter();
        usdt0.mint(address(skim), 10_000e6);
        book.setRouterAllowed(address(skim), true);
        vm.prank(keeper);
        vm.expectRevert(LodestarLoanBook.SwapIncomplete.selector);
        book.settleSwap(id, address(skim), _swapData(950e6), 0);
    }

    function test_OracleDownUsesCachedPriceFloor() public {
        uint256 id = _openFxrp(borrower, 1000e6); // caches $2.50
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        ftso.set(XRP_USD, 0, 8); // FTSO down (BadPrice revert)

        // inside the fallback delay: settlement waits
        vm.prank(keeper);
        vm.expectRevert(LodestarLoanBook.OracleDown.selector);
        book.settleSwap(id, address(router), _swapData(950e6), 0);

        // past the delay the cached $2.50 anchors the floor: a lowball fill still fails
        vm.warp(block.timestamp + 6 days); // now ~8d past due > 7d fallback delay
        router.setRate(10, 10); // $1.00 = 40% of cached value, way under the decayed floor
        vm.prank(keeper);
        vm.expectRevert(LodestarLoanBook.BelowFloor.selector);
        book.settleSwap(id, address(router), _swapData(950e6), 0);

        // a fill near the cached price clears
        router.setRate(25, 10);
        vm.prank(keeper);
        book.settleSwap(id, address(router), _swapData(950e6), 0);
        assertEq(pool.principalOut(), 0, "settled on cached-price floor");
    }

    function test_TierAndKeeperBoundsTightened() public {
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.addTier(address(fxrp), 7500, 7 days, 200); // >70% LTV forbidden
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.setRiskParams(48 hours, 1100, 500, 2000); // keeper >10% forbidden
        vm.expectRevert(LodestarOracle.BadParam.selector);
        oracle.setFeed(address(fxrp), XRP_USD, address(0), 0); // staleness bound mandatory
    }

    function test_WithdrawReserve() public {
        uint256 id = _openFxrp(borrower, 1000e6);
        usdt0.mint(borrower, 1250e6);
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();

        book.withdrawReserve(5e6);
        assertEq(usdt0.balanceOf(reserve), 5e6, "revenue withdrawn to reserve");
        assertEq(book.reserveBalance(), 0);
        vm.prank(borrower);
        vm.expectRevert();
        book.withdrawReserve(1); // only owner
    }
}
