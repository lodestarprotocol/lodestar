// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Can an XRPL user borrow from Lodestar through a Flare Smart Account, with no EVM wallet
///         and no FLR?
///
/// Flare Smart Accounts give every XRPL address a `PersonalAccount` contract on Flare. An XRPL
/// Payment memo commits to a `PackedUserOperation` whose callData is
/// `IPersonalAccount.executeUserOp(Call[])`, and every call in that batch runs with the personal
/// account as `msg.sender`. So the question that decides whether Lodestar can serve XRPL holders is
/// narrow and testable: does our deployed book behave correctly when the borrower is a CONTRACT
/// rather than an EOA, driven through exactly that batch shape?
///
/// This runs against the REAL deployed Coston2 contracts, not mocks of them. The only mock is the
/// account itself, which implements the real `executeUserOp(Call[])` signature so the call shape
/// under test is the production one.
///
/// Run:
///   FORK_RPC=https://coston2-api.flare.network/ext/C/rpc \
///   forge test --match-path test/fork/SmartAccountBorrow.t.sol -vv
interface IBook {
    function open(address collateral, uint256 collAmount, uint256 tierIndex) external returns (uint256 id);
    function repay(uint256 id) external;
    function addCollateral(uint256 id, uint256 amount) external;
    function loans(uint256 id)
        external
        view
        returns (
            address borrower,
            address collateral,
            uint256 collAmount,
            uint128 principal,
            uint128 fee,
            uint128 principalUsd18,
            uint64 openedAt,
            uint64 dueAt,
            bool active,
            uint128 openRate,
            uint128 impairedLoss
        );
    function stable() external view returns (address);
    function minPrincipal() external view returns (uint128);
    function maxActiveLoans() external view returns (uint32);
    function activeLoanCount() external view returns (uint256);
    function exposureCapUsd18(address) external view returns (uint256);
    function setMaxActiveLoans(uint32 n) external;
    function setExposureCap(address collateral, uint256 capUsd18) external;
    function owner() external view returns (address);
    function pool() external view returns (address);
    function activeLoanIds(uint256) external view returns (uint256);
    function paused() external view returns (bool);
}

/// @dev The real Flare Smart Accounts call shape. Copied from IPersonalAccount so the batch we
///      exercise is byte-identical to what the MasterAccountController would dispatch.
struct Call {
    address target;
    uint256 value;
    bytes data;
}

/// @dev Stand-in for a deployed `PersonalAccount`. Deliberately minimal: the point is to prove the
///      book accepts a contract borrower, not to reimplement account abstraction. It holds no
///      approval logic of its own, so the approve MUST come through the batch exactly as it would
///      on chain.
contract MockPersonalAccount {
    error CallFailed(uint256 index, bytes reason);

    function executeUserOp(Call[] calldata _calls) external payable {
        for (uint256 i = 0; i < _calls.length; i++) {
            (bool ok, bytes memory ret) = _calls[i].target.call{value: _calls[i].value}(_calls[i].data);
            if (!ok) revert CallFailed(i, ret);
        }
    }

    /// @dev Only used to read back the loan id, which `executeUserOp` intentionally discards.
    function openDirect(address book, address collateral, uint256 amount, uint256 tier) external returns (uint256) {
        IERC20(collateral).approve(book, amount);
        return IBook(book).open(collateral, amount, tier);
    }
}

contract SmartAccountBorrowTest is Test {
    // Deployed Lodestar on Coston2 (from web/index.html, the live dapp config).
    address constant BOOK = 0x2529C6a1A0aAca615d1479Ea24eB0710b9C3Bc46;
    address constant FXRP = 0x0b6A3645c240605887a5532109323A3E12273dc7;
    // Flare Smart Accounts MasterAccountController — same address on Coston2 and Flare mainnet.
    address constant MAC = 0x434936d47503353f06750Db1A444DBDC5F0AD37c;
    /// @dev A real FXRP holder on Coston2 (1.08M FXRP). vm.deal / StdCheats `deal` CANNOT be used on
    ///      FXRP: it is a checkpointed FAsset, so writing the plain balance slot leaves the
    ///      checkpoint history at zero and the next transferFrom underflows inside the token itself
    ///      (panic 0x11, after emergencyPauseLevel()). Sourcing from a genuine holder keeps the
    ///      token's own accounting intact, which is the only way this test means anything.
    address constant FXRP_WHALE = 0xFf02F742106B8a25C26e65C1f0d66BEC3C90d429;

    IBook book = IBook(BOOK);
    MockPersonalAccount acct;
    address stable;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string("https://coston2-api.flare.network/ext/C/rpc"));
        vm.createSelectFork(rpc);
        acct = new MockPersonalAccount();
        stable = book.stable();

        // Capacity, not smart accounts, is what would otherwise make this revert.
        //
        // The exposure cap is an owner knob, so lift it on the fork. maxActiveLoans is NOT: the
        // contract hard-bounds it to [50, 400] and the live Coston2 book sits at exactly 400/400,
        // so it cannot be raised at all. Free a slot the way the protocol actually allows instead:
        // repay() has no borrower check and always returns collateral to L.borrower, so a third
        // party repaying someone else's loan is both permitted and harmless. That is a real
        // property of the deployed contract, and using it here exercises it.
        address owner = book.owner();
        vm.prank(owner);
        book.setExposureCap(FXRP, 0); // 0 = uncapped

        if (book.activeLoanCount() >= book.maxActiveLoans()) {
            uint256 victim = book.activeLoanIds(0);
            (,,, uint128 owed,,,,, bool wasActive,,) = book.loans(victim);
            require(wasActive, "picked an inactive loan");
            deal(stable, address(this), uint256(owed));
            IERC20(stable).approve(book.pool(), uint256(owed));
            book.repay(victim);
            (,,,,,,,, bool stillActive,,) = book.loans(victim);
            require(!stillActive, "failed to free a slot");
        }
        require(book.activeLoanCount() < book.maxActiveLoans(), "no capacity to open a loan");
    }

    /// @dev The whole flow: one batch that approves and opens, exactly as a 0xFE custom instruction
    ///      would dispatch it, with the account as msg.sender for both calls.
    function test_SmartAccountCanBorrow_ViaExecuteUserOpBatch() public {
        assertFalse(book.paused(), "book paused on fork");

        uint256 collAmount = 1_000e6; // 1,000 FXRP (6dp), comfortably over minPrincipal at 50% LTV
        _fundFxrp(address(acct), collAmount);
        assertEq(IERC20(FXRP).balanceOf(address(acct)), collAmount, "funding failed");

        // The exact batch an XRPL memo would commit to.
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: FXRP,
            value: 0,
            data: abi.encodeCall(IERC20.approve, (BOOK, collAmount))
        });
        calls[1] = Call({
            target: BOOK,
            value: 0,
            data: abi.encodeCall(IBook.open, (FXRP, collAmount, 0))
        });

        uint256 stableBefore = IERC20(stable).balanceOf(address(acct));
        acct.executeUserOp(calls);

        // The account must be the borrower of record, not this test contract and not an EOA.
        uint256 id = _lastLoanOf(address(acct));
        (address borrower,, uint256 coll, uint128 principal,,,,, bool active,,) = book.loans(id);
        assertEq(borrower, address(acct), "borrower must be the personal account");
        assertTrue(active, "loan not active");
        assertEq(coll, collAmount, "collateral mismatch");
        assertGt(principal, 0, "no principal");

        // Borrowed stable must land in the account itself, which is what an XRPL user then controls.
        uint256 got = IERC20(stable).balanceOf(address(acct)) - stableBefore;
        assertGt(got, 0, "no stable disbursed to the smart account");
        emit log_named_uint("principal owed (6dp)", principal);
        emit log_named_uint("stable received (6dp)", got);
        emit log_named_uint("loan id", id);
    }

    /// @dev Round trip. Repayment is the half that decides whether this is usable, not just openable.
    function test_SmartAccountCanRepay_AndGetsCollateralBack() public {
        uint256 collAmount = 1_000e6;
        _fundFxrp(address(acct), collAmount);
        uint256 id = acct.openDirect(BOOK, FXRP, collAmount, 0);

        (,,, uint128 principal,,,,,,,) = book.loans(id);
        // The fee is netted at disbursement, so the account is short of the amount owed. Top it up,
        // which mirrors an XRPL user bringing stable back before repaying.
        deal(stable, address(acct), uint256(principal));

        // repay() pulls the stable through the POOL (pool.pull -> transferFrom), so the pool is the
        // approval target, not the book. Getting this wrong is the most likely integration mistake.
        address pool = book.pool();
        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: stable, value: 0, data: abi.encodeCall(IERC20.approve, (pool, uint256(principal)))});
        calls[1] = Call({target: BOOK, value: 0, data: abi.encodeCall(IBook.repay, (id))});

        uint256 fxrpBefore = IERC20(FXRP).balanceOf(address(acct));
        acct.executeUserOp(calls);

        (,,,,,,,, bool active,,) = book.loans(id);
        assertFalse(active, "loan should be closed");
        uint256 back = IERC20(FXRP).balanceOf(address(acct)) - fxrpBefore;
        assertGt(back, 0, "collateral not returned to the smart account");
        emit log_named_uint("collateral returned (6dp)", back);
    }

    /// @dev The MasterAccountController is deployed at the same address on this network, so the
    ///      derivation the dapp would rely on is live here too.
    function test_MasterAccountControllerIsDeployedOnThisFork() public view {
        assertGt(MAC.code.length, 0, "MasterAccountController not deployed on this network");
    }

    // ---- helpers ----------------------------------------------------------------------------

    /// @dev Move real FXRP from a real holder. See FXRP_WHALE for why `deal` is not an option here.
    function _fundFxrp(address to, uint256 amount) internal {
        require(IERC20(FXRP).balanceOf(FXRP_WHALE) >= amount, "whale too poor on this fork block");
        vm.prank(FXRP_WHALE);
        IERC20(FXRP).transfer(to, amount);
    }

    /// @dev `open` returns the id but `executeUserOp` discards return data, exactly as on chain.
    ///      Recover it from the tail of activeLoanIds: open() pushes the new id last. An earlier
    ///      version scanned 5,000 ids downward and got rate-limited off the public RPC, which is a
    ///      test bug rather than a protocol one, but worth not repeating.
    function _lastLoanOf(address who) internal view returns (uint256) {
        uint256 n = book.activeLoanCount();
        require(n > 0, "no active loans");
        uint256 id = book.activeLoanIds(n - 1);
        (address b,,,,,,,, bool active,,) = book.loans(id);
        require(b == who && active, "newest active loan is not the account's");
        return id;
    }

}
