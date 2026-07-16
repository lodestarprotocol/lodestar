// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LodestarPool
/// @notice ERC4626 lender vault denominated in the stable (USDT0). Lenders earn as
///         borrower fees (and, later, harvested collateral yield) accrue into the pool,
///         lifting the share price. Loans draw from and repay into this pool.
/// @dev Custody of principal-in-flight is tracked via `principalOut` so the share price
///      stays continuous while funds are lent. Only the LoanBook may move funds.
contract LodestarPool is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    address public loanBook;
    uint256 public principalOut; // stable lent out and owed back to the pool
    uint16 public maxUtilizationBps = 8000; // 80% utilization ceiling

    event LoanBookSet(address loanBook);
    event MaxUtilizationSet(uint16 bps);

    error NotLoanBook();
    error OverUtilized();
    error InsufficientLiquidity();
    error AlreadySet();
    error BadParam();

    modifier onlyLoanBook() {
        if (msg.sender != loanBook) revert NotLoanBook();
        _;
    }

    constructor(IERC20 asset_, address _owner) ERC20("Lodestar USDT0 Lender", "lodUSDT0") ERC4626(asset_) Ownable(_owner) {}

    function setLoanBook(address _lb) external onlyOwner {
        if (loanBook != address(0)) revert AlreadySet();
        loanBook = _lb;
        emit LoanBookSet(_lb);
    }

    function setMaxUtilization(uint16 bps) external onlyOwner {
        if (bps > 10_000) revert BadParam();
        maxUtilizationBps = bps;
        emit MaxUtilizationSet(bps);
    }

    /// @dev Total assets = idle balance + principal currently lent out.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + principalOut;
    }

    function available() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Fund a loan. Increases principalOut so share price is unchanged at disbursal.
    function disburse(address to, uint256 amount) external onlyLoanBook {
        if (amount > available()) revert InsufficientLiquidity();
        uint256 ta = totalAssets();
        if ((principalOut + amount) * 10_000 > ta * maxUtilizationBps) revert OverUtilized();
        principalOut += amount;
        IERC20(asset()).safeTransfer(to, amount);
    }

    /// @notice Account that `principal` has come back (or been written off) against the pool.
    function onPrincipalReturned(uint256 principal) external onlyLoanBook {
        principalOut -= principal;
    }

    /// @notice Pull `amount` of stable from `from` into the pool (repayment path).
    function pull(address from, uint256 amount) external onlyLoanBook {
        IERC20(asset()).safeTransferFrom(from, address(this), amount);
    }

    /// @notice Send `amount` of stable out of the pool (reserve cut / surplus routing).
    function payout(address to, uint256 amount) external onlyLoanBook {
        IERC20(asset()).safeTransfer(to, amount);
    }

    /// @dev Extra share precision hardens against ERC4626 first-depositor inflation/donation
    ///      attacks (virtual shares grow by 10**6). Combined with a seeded first deposit in the
    ///      deploy script, this makes share-price manipulation economically infeasible.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
