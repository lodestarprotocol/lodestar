// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Closes the loop: the bytes `tools/xrpl_memo.py` ACTUALLY EMITS, executed against Flare's
///         real deployed MasterAccountController.
///
/// Everything else verifies a layer in isolation. XrplMemoReference.t.sol proves the Python encoder
/// agrees with Solidity on the encoding. XrplEndToEnd.t.sol proves memos built IN SOLIDITY are
/// accepted on chain. Neither proves that what the tool writes to disk, byte for byte, opens a loan
/// -- and a user pastes the tool's output into their wallet, not Solidity's.
///
/// So this reads the tool's own output files and feeds them straight in. Regenerate with:
///
///   python tools/xrpl_memo.py build --xrpl rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh --amount 1000 --tier 0
///
/// writing `setup.memo_hex` and `borrow.memo_hex` to test/fixtures/. The fixtures are committed so
/// this runs without Python, and any drift between the tool and the fixtures shows up as a failure
/// here rather than as a user losing their XRP.
///
/// The fixtures assume the personal account for that XRPL address is at nonce 0, which it is on
/// Coston2 today. If a real operation ever advances it, both fixtures must be regenerated -- the
/// nonce is inside the signed bytes, and XrplNonceSemantics.t.sol proves a stale one reverts.
contract XrplToolBytesExecuteTest is Test {
    address constant MAC = 0x434936d47503353f06750Db1A444DBDC5F0AD37c;
    address constant ASSET_MANAGER_FXRP = 0xc1Ca88b937d0b528842F95d5731ffB586f4fbDFA;
    address constant BOOK = 0x2529C6a1A0aAca615d1479Ea24eB0710b9C3Bc46;
    address constant FXRP = 0x0b6A3645c240605887a5532109323A3E12273dc7;
    address constant FXRP_WHALE = 0xFf02F742106B8a25C26e65C1f0d66BEC3C90d429;
    string constant XRPL_ADDR = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh";
    uint256 constant MINT = 1_000e6; // each Payment mints 1,000 FXRP; the borrow locks 1,000

    address payable executor = payable(address(0xE7EC));
    address pa;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC", string("https://coston2-api.flare.network/ext/C/rpc")));
        pa = IMac2(MAC).getPersonalAccount(XRPL_ADDR);

        address owner = IBook2(BOOK).owner();
        vm.prank(owner);
        IBook2(BOOK).setExposureCap(FXRP, 0); // 0 = uncapped
        if (IBook2(BOOK).activeLoanCount() >= IBook2(BOOK).maxActiveLoans()) {
            uint256 victim = IBook2(BOOK).activeLoanIds(0);
            (,,, uint128 owed,,,,,,,) = IBook2(BOOK).loans(victim);
            address stable = IBook2(BOOK).stable();
            deal(stable, address(this), uint256(owed));
            IERC20(stable).approve(IBook2(BOOK).pool(), uint256(owed));
            IBook2(BOOK).repay(victim);
        }
    }

    function _memo(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(string.concat("test/fixtures/", name)));
    }

    function _fund(uint256 a) internal {
        vm.prank(FXRP_WHALE);
        IERC20(FXRP).transfer(MAC, a);
    }

    /// @dev The fixtures must be the tool's CURRENT output, not a stale copy. Cheap sanity checks
    ///      that would catch a regenerated-with-different-parameters mistake.
    function test_FixturesAreTheExpectedShape() public view {
        bytes memory s = _memo("xrpl_setup_memo.hex");
        bytes memory b = _memo("xrpl_borrow_memo.hex");
        assertEq(s.length, 810, "setup memo length drifted from the tool's output");
        assertEq(b.length, 842, "borrow memo length drifted from the tool's output");
        assertEq(uint8(s[0]), 0xFF, "setup must be an inline 0xFF instruction");
        assertEq(uint8(b[0]), 0xFF, "borrow must be an inline 0xFF instruction");
        assertLe(s.length, 1024, "setup over the XRPL memo cap");
        assertLe(b.length, 1024, "borrow over the XRPL memo cap");
        assertEq(IMac2(MAC).getNonce(pa), 0, "fixtures are built at nonce 0/1; regenerate them");
    }

    /// @notice THE test. Tool output in, loan out, through Flare's real code the whole way.
    function test_ToolBytesOpenALoanOnChain() public {
        // step 1: the setup memo, exactly as the tool wrote it
        _fund(MINT);
        vm.prank(ASSET_MANAGER_FXRP);
        IMac2(MAC).handleMintedFAssets(
            keccak256("tool-setup"), XRPL_ADDR, MINT, 0, _memo("xrpl_setup_memo.hex"), executor, "");
        assertEq(IERC20(FXRP).allowance(pa, BOOK), type(uint256).max,
                 "the tool's setup memo did not grant the approval");
        assertEq(IMac2(MAC).getNonce(pa), 1, "nonce must have advanced to the borrow's");

        // step 2: the borrow memo, exactly as the tool wrote it
        uint256 before = IBook2(BOOK).activeLoanCount();
        _fund(MINT);
        vm.prank(ASSET_MANAGER_FXRP);
        IMac2(MAC).handleMintedFAssets(
            keccak256("tool-borrow"), XRPL_ADDR, MINT, 0, _memo("xrpl_borrow_memo.hex"), executor, "");

        uint256 n = IBook2(BOOK).activeLoanCount();
        assertEq(n, before + 1, "the tool's borrow memo did not open a loan");
        uint256 id = IBook2(BOOK).activeLoanIds(n - 1);
        (address borrower,, uint256 coll, uint128 principal,,,,, bool active,,) = IBook2(BOOK).loans(id);
        assertEq(borrower, pa, "borrower must be the XRPL user's personal account");
        assertEq(coll, MINT, "collateral must be exactly what the tool encoded");
        assertTrue(active, "loan not active");
        assertGt(principal, 0, "no principal");

        console2.log("loan opened from PYTHON-generated memo bytes");
        console2.log("  loan id", id);
        console2.log("  collateral (6dp)", coll);
        console2.log("  principal owed (6dp)", principal);
        console2.log("  USD0 at personal account (6dp)", IERC20(IBook2(BOOK).stable()).balanceOf(pa));
    }

    /// @dev Order is not advisory. Sending the borrow memo first must fail, because it is built at
    ///      nonce 1 and the account is at 0. This is the failure a user would hit by sending their
    ///      two XRPL Payments in the wrong order, so it is worth proving rather than documenting.
    function test_BorrowMemoAloneIsRejected() public {
        _fund(MINT);
        vm.prank(ASSET_MANAGER_FXRP);
        vm.expectRevert();
        IMac2(MAC).handleMintedFAssets(
            keccak256("tool-out-of-order"), XRPL_ADDR, MINT, 0, _memo("xrpl_borrow_memo.hex"), executor, "");
    }
}

interface IMac2 {
    function handleMintedFAssets(bytes32, string calldata, uint256, uint256, bytes calldata,
                                 address payable, bytes calldata) external payable;
    function getPersonalAccount(string calldata) external view returns (address);
    function getNonce(address) external view returns (uint256);
}

interface IBook2 {
    function repay(uint256 id) external;
    function loans(uint256 id) external view returns (
        address borrower, address collateral, uint256 collAmount, uint128 principal, uint128 fee,
        uint128 principalUsd18, uint64 openedAt, uint64 dueAt, bool active, uint128 openRate,
        uint128 impairedLoss);
    function stable() external view returns (address);
    function owner() external view returns (address);
    function pool() external view returns (address);
    function activeLoanCount() external view returns (uint256);
    function maxActiveLoans() external view returns (uint32);
    function activeLoanIds(uint256) external view returns (uint256);
    function setExposureCap(address collateral, uint256 capUsd18) external;
}
