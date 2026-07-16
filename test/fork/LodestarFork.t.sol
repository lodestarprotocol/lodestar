// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LodestarOracle} from "../../src/LodestarOracle.sol";
import {LodestarPool} from "../../src/LodestarPool.sol";
import {LodestarLoanBook} from "../../src/LodestarLoanBook.sol";
import {SceptreRateAdapter} from "../../src/flare/SceptreRateAdapter.sol";
import {FlareAddresses as FA} from "../../src/flare/FlareAddresses.sol";

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
        vm.createSelectFork("https://flare-api.flare.network/ext/C/rpc");

        oracle = new LodestarOracle(FA.FTSO_V2, owner);
        SceptreRateAdapter rate = new SceptreRateAdapter(FA.SFLR);
        oracle.setFeed(FA.FXRP, FA.FEED_XRP_USD, address(0), 6 hours);
        oracle.setFeed(FA.SFLR, FA.FEED_FLR_USD, address(rate), 6 hours);

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
}
