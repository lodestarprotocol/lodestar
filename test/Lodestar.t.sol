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
        oracle.setFeed(address(fxrp), XRP_USD, address(0), 0);
        oracle.setFeed(address(sflr), FLR_USD, address(sflrRate), 0);

        pool = new LodestarPool(IERC20(address(usdt0)), owner);
        book = new LodestarLoanBook(pool, oracle, reserve, owner);
        pool.setLoanBook(address(book));

        router = new MockRouter();
        book.setRouter(router);

        // FXRP tier: 50% LTV, 7d, 2% fee. sFLR tier: 60% LTV, 30d, 3% fee.
        book.addTier(address(fxrp), 5000, 7 days, 200);
        book.addTier(address(sflr), 6000, 30 days, 300);

        // seed lender pool with 100k USDT0
        usdt0.mint(lender, 100_000e6);
        vm.startPrank(lender);
        usdt0.approve(address(pool), type(uint256).max);
        pool.deposit(100_000e6, lender);
        vm.stopPrank();

        // router liquidity for settlement swaps
        usdt0.mint(address(router), 1_000_000e6);
    }

    function test_OpenAndRepay() public {
        // borrower locks 1000 FXRP (@ $2.50 = $2500), 50% LTV -> $1250 principal, 2% fee = $25
        fxrp.mint(borrower, 1000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(fxrp), 1000e6, 0);
        vm.stopPrank();

        assertEq(usdt0.balanceOf(borrower), 1250e6, "principal disbursed");
        assertEq(pool.principalOut(), 1250e6, "principalOut tracked");

        uint256 spBefore = pool.totalAssets();

        // repay principal + fee
        usdt0.mint(borrower, 25e6); // borrower tops up to cover fee
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();

        assertEq(fxrp.balanceOf(borrower), 1000e6, "collateral returned");
        assertEq(pool.principalOut(), 0, "principal cleared");
        // lenders earned 80% of the 25 fee = 20 (reserve took 5)
        assertEq(usdt0.balanceOf(reserve), 5e6, "reserve cut");
        assertApproxEqAbs(pool.totalAssets(), spBefore + 20e6, 1, "lender yield accrued");
    }

    function test_NoLiquidationOnPriceCrash() public {
        fxrp.mint(borrower, 1000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(fxrp), 1000e6, 0);
        vm.stopPrank();

        // XRP crashes 60% -> collateral now worth $1000 < debt. Traditional lender would liquidate.
        ftso.set(XRP_USD, 100_000_000, 8); // $1.00

        // Lodestar: cannot be settled while inside the term, no matter the price.
        vm.expectRevert(LodestarLoanBook.NotYetDefaulted.selector);
        book.settle(id, 0);

        // still repayable and collateral still the borrower's
        assertTrue(book.isDefaulted(id) == false, "not defaulted mid-term");
    }

    function test_DefaultSettlement() public {
        fxrp.mint(borrower, 1000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(fxrp), 1000e6, 0);
        vm.stopPrank();

        // router pays $2.50 per FXRP (num/den on 6dp->6dp): out = amountIn * 25 / 10
        router.setRate(25, 10);

        // move past deadline (7d) + grace (48h)
        vm.warp(block.timestamp + 7 days + 48 hours + 1);
        assertTrue(book.isDefaulted(id), "defaulted");

        uint256 poolBefore = pool.totalAssets();
        vm.prank(keeper);
        book.settle(id, 0);

        // keeper got 5% of 1000 FXRP in-kind
        assertEq(fxrp.balanceOf(keeper), 50e6, "keeper bounty in-kind");
        // pool made whole on principal (1250) + fee share; principalOut cleared
        assertEq(pool.principalOut(), 0, "principal cleared");
        assertGe(pool.totalAssets(), poolBefore, "lenders made whole");
        // borrower received surplus (collateral was worth well over the debt)
        assertGt(usdt0.balanceOf(borrower) - 1250e6, 0, "surplus returned to borrower");
    }

    function test_sFLRYieldStaysWithBorrower() public {
        // borrower locks 100k sFLR (@ $0.02 = $2000), 60% LTV -> $1200 principal
        sflr.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(sflr), 100_000e18, 0);
        vm.stopPrank();
        assertEq(usdt0.balanceOf(borrower), 1200e6, "principal @60% LTV");

        // while locked, sFLR appreciates 10% vs FLR (staking yield)
        sflrRate.set(1.1e18);

        // repay: borrower gets back the SAME 100k sFLR — now worth 10% more. Yield kept.
        usdt0.mint(borrower, 36e6); // 3% fee
        vm.startPrank(borrower);
        usdt0.approve(address(pool), type(uint256).max);
        book.repay(id);
        vm.stopPrank();
        assertEq(sflr.balanceOf(borrower), 100_000e18, "full yield-bearing collateral returned");
    }

    function test_RejectsDustLoan() public {
        // a tiny sFLR amount values to < 1 stable unit of principal -> must revert, not create dust
        sflr.mint(borrower, 1e9);
        vm.startPrank(borrower);
        sflr.approve(address(book), type(uint256).max);
        vm.expectRevert(LodestarLoanBook.BadParam.selector);
        book.open(address(sflr), 1e9, 0);
        vm.stopPrank();
    }

    function test_SettleFloorEnforced() public {
        fxrp.mint(borrower, 1000e6);
        vm.startPrank(borrower);
        fxrp.approve(address(book), type(uint256).max);
        uint256 id = book.open(address(fxrp), 1000e6, 0);
        vm.stopPrank();

        // router would only return ~$1900 for collateral FTSO-valued at ~$2375 -> below the 98% floor
        router.setRate(20, 10);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);

        vm.prank(keeper);
        vm.expectRevert(bytes("MockRouter: slippage"));
        book.settle(id, 0); // keeper cannot route value away below the FTSO floor
    }
}
