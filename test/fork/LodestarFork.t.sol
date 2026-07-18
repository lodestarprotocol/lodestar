// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {SceptreRateAdapter} from "../../src/flare/SceptreRateAdapter.sol";
import {FirelightRateAdapter} from "../../src/flare/FirelightRateAdapter.sol";
import {FlareAddresses as FA} from "../../src/flare/FlareAddresses.sol";

/// @dev SparkDEX V4 (Algebra) router multi-hop entrypoint. Same selector as UniV3 exactInput
///      (0xc04b8d59); the path packs a 20-byte deployer (0 = base pools) between tokens.
interface IAlgebraRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @dev SparkDEX V3.1 (UniswapV3-fork) periphery, verified on Flare mainnet.
interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Live-Flare fork tests. Run with a Flare RPC:
///   forge test --match-path test/fork/LodestarFork.t.sol --fork-url https://flare-api.flare.network/ext/C/rpc -vv
/// setUp also self-forks so it runs without the flag.
contract LodestarForkTest is Test {
    LodestarOracle oracle;
    LodestarPool pool;
    LodestarLoanBook book;

    address owner = address(this);
    address reserve = address(0xEE5E);
    address lender = address(0x1E7D);
    address borrower = address(0xB0B);

    function setUp() public {
        // FORK_RPC lets us point at our own un-rate-limited node for heavy multi-hop swap tests
        // (the public RPC 429s on Algebra 2-hop tick traversal). Defaults to the public endpoint.
        vm.createSelectFork(vm.envOr("FORK_RPC", string("https://flare-api.flare.network/ext/C/rpc")));

        oracle = new LodestarOracle(FA.FTSO_V2, owner);
        SceptreRateAdapter rate = new SceptreRateAdapter(FA.SFLR);
        oracle.setFeed(FA.FXRP, FA.FEED_XRP_USD, address(0), 1 hours, 0);
        oracle.setFeed(FA.SFLR, FA.FEED_FLR_USD, address(rate), 1 hours, 0);

        pool = new LodestarPool(IERC20(FA.USDT0), owner);
        book = new LodestarLoanBook(pool, oracle, reserve, owner);
        pool.setLoanBook(address(book));
        book.addTier(FA.FXRP, 5000, 7 days, 200);
        book.addTier(FA.SFLR, 6000, 30 days, 300);
    }

    function test_fork_RealFtsoPrices() public {
        uint256 pXrp = oracle.priceUsd18(FA.FXRP);
        uint256 pSflr = oracle.priceUsd18(FA.SFLR);
        emit log_named_decimal_uint("FXRP price USD", pXrp, 18);
        emit log_named_decimal_uint("sFLR price USD", pSflr, 18);
        assertGt(pXrp, 0.2e18);
        assertLt(pXrp, 20e18);
        assertGt(pSflr, 0.001e18);
        assertLt(pSflr, 1e18);
    }

    // real mainnet holders (proxies use ERC-7201 storage, so `deal` can't set balances)
    address constant FXRP_WHALE = 0x4C18Ff3C89632c3Dd62E796c0aFA5c07c4c1B2b3;
    address constant USDT0_WHALE = 0x0B40111B4Cf6dD1001F36f9c631956FefA56BC3b;

    function _fund(address token, address whale, address to, uint256 amount) internal {
        vm.prank(whale);
        IERC20(token).transfer(to, amount);
    }

    function test_fork_OpenLoanAgainstFXRP() public {
        uint256 sUnit = 10 ** IERC20Metadata(FA.USDT0).decimals();
        _fund(FA.USDT0, USDT0_WHALE, lender, 100_000 * sUnit);
        vm.startPrank(lender);
        IERC20(FA.USDT0).approve(address(pool), type(uint256).max);
        pool.deposit(100_000 * sUnit, lender);
        vm.stopPrank();

        uint256 xUnit = 10 ** IERC20Metadata(FA.FXRP).decimals();
        _fund(FA.FXRP, FXRP_WHALE, borrower, 1000 * xUnit);
        vm.startPrank(borrower);
        IERC20(FA.FXRP).approve(address(book), type(uint256).max);
        uint256 id = book.open(FA.FXRP, 1000 * xUnit, 0);
        vm.stopPrank();

        uint256 principal = IERC20(FA.USDT0).balanceOf(borrower);
        emit log_named_uint("loanId", id);
        emit log_named_decimal_uint("principal disbursed", principal, IERC20Metadata(FA.USDT0).decimals());
        assertGt(principal, 200 * sUnit); // >= ~$200 against 1000 FXRP at 50% LTV
    }

    // ------------------------------------------------------------- v1.3 mainnet-state lifecycle
    // These two tests answer "does this truly work on mainnet": full open -> default -> settle
    // against real FXRP, the real FTSO, real USDT0 holders, and (for the swap path) the REAL
    // SparkDEX V3.1 router and its live FXRP/USDT0 0.05% pool. No mocks anywhere.

    address constant SPARKDEX_V31_ROUTER = 0x8a1E35F5c98C4E85B36B7B253222eE17773b2781;

    /// @dev Short-lived tier + fast Dutch decay so the whole lifecycle stays inside the FTSO
    ///      staleness window while warping (fork timestamps don't refresh the real feed).
    function _prepShortLoan() internal returns (uint256 id, uint256 principal) {
        // Keep the whole lifecycle inside the 1h FTSO-staleness window: on a frozen fork the real
        // feed timestamp doesn't advance, so warping past maxStale would read as stale. Short tier
        // + short grace; decay period stays at its 1h minimum but we settle partway down the curve.
        book.addTier(FA.FXRP, 5000, 10 minutes, 200);
        uint256 shortTier = book.tierCount(FA.FXRP) - 1;
        book.setRiskParams(10 minutes, 500, 500, 2000); // 10-min grace
        book.setSettleCurve(10_000, 8_500, 1 hours); // 100->85% over 1h (min allowed period)

        uint256 sUnit = 10 ** IERC20Metadata(FA.USDT0).decimals();
        _fund(FA.USDT0, USDT0_WHALE, lender, 100_000 * sUnit);
        vm.startPrank(lender);
        IERC20(FA.USDT0).approve(address(pool), type(uint256).max);
        pool.deposit(100_000 * sUnit, lender);
        vm.stopPrank();

        uint256 xUnit = 10 ** IERC20Metadata(FA.FXRP).decimals();
        _fund(FA.FXRP, FXRP_WHALE, borrower, 1000 * xUnit);
        vm.startPrank(borrower);
        IERC20(FA.FXRP).approve(address(book), type(uint256).max);
        id = book.open(FA.FXRP, 1000 * xUnit, shortTier);
        vm.stopPrank();
        (,,, principal,,,,,,,) = book.loans(id);
    }

    function test_fork_FullLifecycle_BuyoutOnMainnetState() public {
        (uint256 id,) = _prepShortLoan();
        address buyer = address(0xB1D);

        vm.warp(block.timestamp + 30 minutes); // past due (10m) + grace (10m), ~10m into decay
        assertTrue(book.isDefaulted(id), "defaulted");

        uint256 cost = book.buyoutCost(id);
        _fund(FA.USDT0, USDT0_WHALE, buyer, cost);
        uint256 poolBefore = pool.totalAssets();
        vm.startPrank(buyer);
        IERC20(FA.USDT0).approve(address(book), cost);
        book.buyout(id, cost);
        vm.stopPrank();

        assertEq(IERC20(FA.FXRP).balanceOf(buyer), 1000e6, "buyer received real FXRP");
        assertEq(pool.principalOut(), 0, "principal cleared");
        assertGe(pool.totalAssets(), poolBefore, "lenders whole on mainnet state");
        emit log_named_decimal_uint("buyout cost USDT0", cost, 6);
    }

    function test_fork_SettleSwapThroughRealSparkDEX() public {
        (uint256 id, uint256 principal) = _prepShortLoan();
        book.setRouterAllowed(SPARKDEX_V31_ROUTER, true);

        vm.warp(block.timestamp + 50 minutes); // default at 20m, 30m into the 1h decay -> 92.5%
        assertEq(book.currentFloorBps(id), 9_250, "unexpected partial-decay floor");

        // keeper sells collateral minus the 5% bounty through the LIVE SparkDEX V3.1 pool
        uint256 toSell = 1000e6 - 50e6;
        bytes memory swapData = abi.encodeCall(
            ISwapRouterV3.exactInputSingle,
            (
                ISwapRouterV3.ExactInputSingleParams({
                    tokenIn: FA.FXRP,
                    tokenOut: FA.USDT0,
                    fee: 500,
                    recipient: address(book),
                    deadline: block.timestamp,
                    amountIn: toSell,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );

        address keeper = address(0xC0FFEE);
        uint256 poolBefore = pool.totalAssets();
        vm.prank(keeper);
        book.settleSwap(id, SPARKDEX_V31_ROUTER, swapData, 0);

        assertEq(IERC20(FA.FXRP).balanceOf(keeper), 50e6, "keeper bounty in-kind");
        assertEq(pool.principalOut(), 0, "principal cleared via real DEX settlement");
        assertGe(pool.totalAssets(), poolBefore, "lenders whole through the real pool");
        (,,,,,,,, bool active,,) = book.loans(id);
        assertFalse(active, "loan closed");
        emit log_named_decimal_uint("principal repaid via SparkDEX", principal, 6);
    }

    // sFLR (18dp) full lifecycle on REAL mainnet state, settled via BUYOUT (the always-available path,
    // no DEX dependency). sFLR ALSO has deep swap liquidity (sFLR/WFLR ~$1.05M on SparkDEX V4, so the
    // keeper's swap route works too), but buyout is the cleanest thing to prove on a fork. Funded from
    // a real sFLR holder (the SparkDEX sFLR/WFLR pool).
    address constant SFLR_HOLDER = 0x9A3215f8B0d128816F75175c9fD74e7ebbD987DA;

    function test_fork_SflrSettlesViaBuyoutOnMainnetState() public {
        // short sFLR tier so the whole lifecycle stays inside the 1h FTSO staleness window on a frozen fork
        book.addTier(FA.SFLR, 5000, 10 minutes, 200);
        uint256 shortTier = book.tierCount(FA.SFLR) - 1;
        book.setRiskParams(10 minutes, 500, 500, 2000);
        book.setSettleCurve(10_000, 8_500, 1 hours);

        uint256 sUnit = 10 ** IERC20Metadata(FA.USDT0).decimals();
        _fund(FA.USDT0, USDT0_WHALE, lender, 50_000 * sUnit);
        vm.startPrank(lender);
        IERC20(FA.USDT0).approve(address(pool), type(uint256).max);
        pool.deposit(50_000 * sUnit, lender);
        vm.stopPrank();

        uint256 collAmt = 20_000e18; // ~$236 of sFLR
        _fund(FA.SFLR, SFLR_HOLDER, borrower, collAmt);
        vm.startPrank(borrower);
        IERC20(FA.SFLR).approve(address(book), type(uint256).max);
        uint256 id = book.open(FA.SFLR, collAmt, shortTier);
        vm.stopPrank();
        (,,, uint256 principal,,,,,,,) = book.loans(id);
        assertGt(principal, 0, "sFLR loan opened on mainnet state");

        vm.warp(block.timestamp + 30 minutes); // past due (10m) + grace (10m)
        assertTrue(book.isDefaulted(id), "sFLR defaulted");

        address buyer = address(0xB2D);
        uint256 cost = book.buyoutCost(id);
        _fund(FA.USDT0, USDT0_WHALE, buyer, cost);
        uint256 poolBefore = pool.totalAssets();
        vm.startPrank(buyer);
        IERC20(FA.USDT0).approve(address(book), cost);
        book.buyout(id, cost);
        vm.stopPrank();

        assertEq(IERC20(FA.SFLR).balanceOf(buyer), collAmt, "buyer received real sFLR");
        assertEq(pool.principalOut(), 0, "sFLR principal cleared");
        assertGe(pool.totalAssets(), poolBefore, "lenders whole on real sFLR buyout");
        emit log_named_decimal_uint("sFLR buyout cost USDT0", cost, 6);
    }

    // stXRP (6dp) settled by the keeper's REAL route: SparkDEX V4 (Algebra) 2-hop stXRP->FXRP->USD₮0,
    // against the live ~$5.8M stXRP/FXRP pool. Proves the deep DEX path + the FirelightRateAdapter
    // pricing + the Algebra multi-hop calldata all work on real mainnet state. Funded from the pool.
    address constant SPARKDEX_V4 = 0x69D57B9D705eaD73a5d2f2476C30c55bD755cc2F;
    address constant STXRP_HOLDER = 0x2a91D9296ee2fe4139b49c7071b2f29f59a9f9aE; // SparkDEX V4 stXRP/FXRP pool

    function test_fork_StxrpSettleSwapThroughSparkDexV4() public {
        // The Algebra 2-hop swap reads deep pool tick state: it 429s on the public RPC and needs an
        // archival/own-node fork run STANDALONE (a pruned node loses the fork block's state during the
        // long full suite). Opt in explicitly:  HEAVY_FORK=1 FORK_RPC=<node> forge test --match-test stXRP
        if (bytes(vm.envOr("HEAVY_FORK", string(""))).length == 0) {
            emit log("skip: set HEAVY_FORK=1 + FORK_RPC=<archival node> to run the stXRP Algebra 2-hop settle test");
            return;
        }
        FirelightRateAdapter rate = new FirelightRateAdapter(FA.STXRP);
        oracle.setFeed(FA.STXRP, FA.FEED_XRP_USD, address(rate), 1 hours, 300);
        book.addTier(FA.STXRP, 5000, 10 minutes, 200);
        uint256 tier = book.tierCount(FA.STXRP) - 1;
        book.setRiskParams(10 minutes, 500, 500, 2000);
        book.setSettleCurve(10_000, 8_500, 1 hours);
        book.setRouterAllowed(SPARKDEX_V4, true);

        _fund(FA.USDT0, USDT0_WHALE, lender, 100_000e6);
        vm.startPrank(lender);
        IERC20(FA.USDT0).approve(address(pool), type(uint256).max);
        pool.deposit(100_000e6, lender);
        vm.stopPrank();

        uint256 collAmt = 10_000e6; // ~10k stXRP (~$10.5k), <1% of the pool -> low slippage
        _fund(FA.STXRP, STXRP_HOLDER, borrower, collAmt);
        vm.startPrank(borrower);
        IERC20(FA.STXRP).approve(address(book), type(uint256).max);
        uint256 id = book.open(FA.STXRP, collAmt, tier);
        vm.stopPrank();
        (,,, uint256 principal,,,,,,,) = book.loans(id);

        vm.warp(block.timestamp + 50 minutes); // default at 20m, 30m into the 1h decay (floor ~92.5%)
        assertTrue(book.isDefaulted(id), "stXRP defaulted");

        // replicate the contract's bounty so amountIn == the contract's toSell (else SwapIncomplete)
        uint256 p18 = oracle.priceUsd18(FA.STXRP);
        uint256 bounty = (collAmt * book.keeperBps()) / 10_000;
        uint256 cap = (uint256(book.keeperCapUsd18()) * 1e6) / p18; // stXRP unit = 1e6
        if (bounty > cap) bounty = cap;
        uint256 toSell = collAmt - bounty;

        // Algebra 2-hop path stXRP -> FXRP -> USD₮0 (20-byte deployer=0 between tokens)
        bytes memory path = abi.encodePacked(FA.STXRP, bytes20(0), FA.FXRP, bytes20(0), FA.USDT0);
        bytes memory swapData = abi.encodeCall(
            IAlgebraRouter.exactInput,
            (
                IAlgebraRouter.ExactInputParams({
                    path: path,
                    recipient: address(book),
                    deadline: block.timestamp,
                    amountIn: toSell,
                    amountOutMinimum: 0
                })
            )
        );

        address keeper = address(0xCafE);
        uint256 poolBefore = pool.totalAssets();
        vm.prank(keeper);
        book.settleSwap(id, SPARKDEX_V4, swapData, 0);

        assertEq(IERC20(FA.STXRP).balanceOf(keeper), bounty, "stXRP keeper bounty in-kind");
        assertEq(pool.principalOut(), 0, "principal cleared via SparkDEX V4 Algebra 2-hop");
        assertGe(pool.totalAssets(), poolBefore, "lenders whole through the real stXRP/FXRP pool");
        (,,,,,,,, bool active,,) = book.loans(id);
        assertFalse(active, "loan closed");
        emit log_named_decimal_uint("stXRP principal repaid via SparkDEX V4", principal, 6);
    }
}
