// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The whole XRPL borrow, driven through Flare's REAL deployed entrypoint.
///
/// The earlier fork test proved our book accepts a contract borrower using the executeUserOp batch
/// shape. It did not prove that Flare's own machinery produces that call from a memo. This does: it
/// calls MasterAccountController.handleMintedFAssets exactly as the FAssets AssetManager does during
/// direct minting, with a memo built to the byte layout in the deployed MemoInstructions library.
///
/// Everything downstream of that call is Flare's real code on the fork: the PersonalAccount is
/// created by their factory, the FXRP is distributed by their accounting, the memo is parsed by
/// their library, and the user operation is dispatched by them into our book.
///
/// What is NOT covered, and is the only remaining gap: the XRPL payment itself and the FDC
/// attestation proof. Those sit upstream of handleMintedFAssets and cannot be forked.
///
/// From the deployed facet, the preconditions this test must satisfy:
///   require(msg.sender == address(ContractRegistry.getAssetManagerFXRP()), OnlyAssetManager());
///   ... _distributeFAssets does `fAsset.safeTransfer(_personalAccount, remaining)`
///       so the CONTROLLER must already hold the FXRP when it is called
///   require(!state.usedTransactionIds[_transactionId], TransactionAlreadyExecuted());
///   _executorFee = uint64(bytes8(_memoData[2:10]));
///   require(_amount >= _executorFee, ...);
///
/// Run:
///   FORK_RPC=https://coston2-api.flare.network/ext/C/rpc \
///   forge test --match-path test/fork/XrplEndToEnd.t.sol -vv
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

struct Call {
    address target;
    uint256 value;
    bytes data;
}

interface IPersonalAccount {
    function executeUserOp(Call[] calldata _calls) external payable;
}

interface IMasterAccountController {
    function handleMintedFAssets(
        bytes32 _transactionId,
        string calldata _sourceAddress,
        uint256 _amount,
        uint256 _underlyingTimestamp,
        bytes calldata _memoData,
        address payable _executor,
        bytes calldata _data
    ) external payable;

    function getPersonalAccount(string calldata _xrplOwner) external view returns (address);
    function getNonce(address _personalAccount) external view returns (uint256);
}

interface IBook {
    function open(address collateral, uint256 collAmount, uint256 tierIndex) external returns (uint256);
    function repay(uint256 id) external;
    function loans(uint256 id) external view returns (
        address borrower, address collateral, uint256 collAmount, uint128 principal, uint128 fee,
        uint128 principalUsd18, uint64 openedAt, uint64 dueAt, bool active, uint128 openRate,
        uint128 impairedLoss);
    function stable() external view returns (address);
    function owner() external view returns (address);
    function pool() external view returns (address);
    function paused() external view returns (bool);
    function activeLoanCount() external view returns (uint256);
    function maxActiveLoans() external view returns (uint32);
    function activeLoanIds(uint256) external view returns (uint256);
    function setExposureCap(address collateral, uint256 capUsd18) external;
}

contract XrplEndToEndTest is Test {
    address constant MAC = 0x434936d47503353f06750Db1A444DBDC5F0AD37c;
    address constant ASSET_MANAGER_FXRP = 0xc1Ca88b937d0b528842F95d5731ffB586f4fbDFA; // Coston2
    address constant BOOK = 0x2529C6a1A0aAca615d1479Ea24eB0710b9C3Bc46;
    address constant FXRP = 0x0b6A3645c240605887a5532109323A3E12273dc7;
    // See SmartAccountBorrow.t.sol: FXRP is a checkpointed FAsset, so forge `deal` corrupts it and a
    // real holder must be used.
    address constant FXRP_WHALE = 0xFf02F742106B8a25C26e65C1f0d66BEC3C90d429;

    string constant XRPL_ADDR = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh";
    uint256 constant MINT_AMOUNT = 1_000e6; // 1,000 FXRP arriving from the mint
    address payable executor = payable(address(0xE7EC));

    IMasterAccountController mac = IMasterAccountController(MAC);
    IBook book = IBook(BOOK);
    address pa;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC", string("https://coston2-api.flare.network/ext/C/rpc")));
        pa = mac.getPersonalAccount(XRPL_ADDR);

        // Capacity: the live book sits at 400/400 and maxActiveLoans is hard-bounded to 400, so a
        // slot is freed the way the protocol allows -- repay() has no borrower check and always
        // returns collateral to L.borrower, so a third party repaying is permitted and harmless.
        address owner = book.owner();
        vm.prank(owner);
        book.setExposureCap(FXRP, 0);
        if (book.activeLoanCount() >= book.maxActiveLoans()) {
            uint256 victim = book.activeLoanIds(0);
            (,,, uint128 owed,,,,,,,) = book.loans(victim);
            address stable = book.stable();
            deal(stable, address(this), uint256(owed)); // USD₮0 is a plain ERC20, deal is safe here
            IERC20(stable).approve(book.pool(), uint256(owed));
            book.repay(victim);
        }
    }

    function _calls(uint256 amount) internal pure returns (Call[] memory c) {
        c = new Call[](2);
        c[0] = Call({target: FXRP, value: 0, data: abi.encodeCall(IERC20.approve, (BOOK, amount))});
        c[1] = Call({target: BOOK, value: 0, data: abi.encodeCall(IBook.open, (FXRP, amount, 0))});
    }

    function _userOp(uint256 amount) internal view returns (PackedUserOperation memory op) {
        op = PackedUserOperation({
            sender: pa,
            nonce: mac.getNonce(pa),
            initCode: "",
            callData: abi.encodeCall(IPersonalAccount.executeUserOp, (_calls(amount))),
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });
    }

    /// @dev Simulate the mint: the controller holds the FXRP when handleMintedFAssets runs.
    function _fundController(uint256 amount) internal {
        vm.prank(FXRP_WHALE);
        IERC20(FXRP).transfer(MAC, amount);
    }

    function _assertLoanOpened(string memory label) internal view {
        uint256 n = book.activeLoanCount();
        uint256 id = book.activeLoanIds(n - 1);
        (address borrower,, uint256 coll, uint128 principal,,,,, bool active,,) = book.loans(id);
        assertEq(borrower, pa, "borrower must be the XRPL user's personal account");
        assertTrue(active, "loan not active");
        assertGt(principal, 0, "no principal");
        console2.log(label);
        console2.log("  loan id", id);
        console2.log("  collateral (6dp)", coll);
        console2.log("  principal owed (6dp)", principal);
        console2.log("  stable at personal account (6dp)", IERC20(book.stable()).balanceOf(pa));
    }

    /// @notice 0xFE: memo carries only the hash, the executor supplies the bytes.
    function test_FullFlow_0xFE_HashCommitment() public {
        assertFalse(book.paused(), "book paused");
        _fundController(MINT_AMOUNT);

        PackedUserOperation memory op = _userOp(MINT_AMOUNT);
        bytes memory data = abi.encode(op);
        bytes memory memo = abi.encodePacked(bytes1(0xFE), bytes1(uint8(0)), bytes8(uint64(0)), keccak256(data));
        assertEq(memo.length, 42, "0xFE memo must be 42 bytes");

        vm.prank(ASSET_MANAGER_FXRP);
        mac.handleMintedFAssets(keccak256("xrpl-tx-fe"), XRPL_ADDR, MINT_AMOUNT, 0, memo, executor, data);

        _assertLoanOpened("0xFE flow");
    }

    /// @notice 0xFF: the whole operation inlined in the memo, no executor data channel at all.
    /// @dev Measured: a 2-call batch is 1,098 bytes of memo, over XRPL's 1,024 cap, so this shape is
    ///      NOT usable on a real XRPL payment. It is exercised here to prove the on-chain path works,
    ///      because the production design splits into a one-time approve then single-call borrows,
    ///      both of which do fit. See test_FullFlow_0xFF_SingleCall_FitsXrplMemoCap.
    function test_FullFlow_0xFF_Inline() public {
        _fundController(MINT_AMOUNT);
        PackedUserOperation memory op = _userOp(MINT_AMOUNT);
        bytes memory memo = abi.encodePacked(bytes1(0xFF), bytes1(uint8(0)), bytes8(uint64(0)), abi.encode(op));

        vm.prank(ASSET_MANAGER_FXRP);
        mac.handleMintedFAssets(keccak256("xrpl-tx-ff"), XRPL_ADDR, MINT_AMOUNT, 0, memo, executor, "");

        _assertLoanOpened("0xFF flow");
        console2.log("  0xFF memo bytes", memo.length);
    }

    /// @notice The production shape: approve once, then every borrow is a single call whose 0xFF memo
    ///         fits inside XRPL's 1,024-byte cap, so no executor ever needs to hold our bytes.
    function test_FullFlow_0xFF_SingleCall_FitsXrplMemoCap() public {
        // step 1: one-time approval, itself an inline instruction
        _fundController(MINT_AMOUNT);
        Call[] memory setup = new Call[](1);
        setup[0] = Call({target: FXRP, value: 0,
                         data: abi.encodeCall(IERC20.approve, (BOOK, type(uint256).max))});
        PackedUserOperation memory op1 = PackedUserOperation({
            sender: pa, nonce: mac.getNonce(pa), initCode: "",
            callData: abi.encodeCall(IPersonalAccount.executeUserOp, (setup)),
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: ""});
        bytes memory memo1 = abi.encodePacked(bytes1(0xFF), bytes1(uint8(0)), bytes8(uint64(0)), abi.encode(op1));
        assertLe(memo1.length, 1024, "setup memo must fit the XRPL cap");

        vm.prank(ASSET_MANAGER_FXRP);
        mac.handleMintedFAssets(keccak256("xrpl-setup"), XRPL_ADDR, MINT_AMOUNT, 0, memo1, executor, "");
        assertEq(IERC20(FXRP).allowance(pa, BOOK), type(uint256).max, "approval not set");

        // step 2: borrow, a single call, no approve needed
        _fundController(MINT_AMOUNT);
        Call[] memory borrow = new Call[](1);
        borrow[0] = Call({target: BOOK, value: 0,
                          data: abi.encodeCall(IBook.open, (FXRP, MINT_AMOUNT * 2, 0))});
        PackedUserOperation memory op2 = PackedUserOperation({
            sender: pa, nonce: mac.getNonce(pa), initCode: "",
            callData: abi.encodeCall(IPersonalAccount.executeUserOp, (borrow)),
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: ""});
        bytes memory memo2 = abi.encodePacked(bytes1(0xFF), bytes1(uint8(0)), bytes8(uint64(0)), abi.encode(op2));
        assertLe(memo2.length, 1024, "borrow memo must fit the XRPL cap");

        vm.prank(ASSET_MANAGER_FXRP);
        mac.handleMintedFAssets(keccak256("xrpl-borrow"), XRPL_ADDR, MINT_AMOUNT, 0, memo2, executor, "");

        _assertLoanOpened("0xFF single-call flow (production shape)");
        console2.log("  setup memo bytes", memo1.length);
        console2.log("  borrow memo bytes", memo2.length);
    }

    /// @dev Replay protection is Flare's, not ours, but a duplicated XRPL txId must not open a second
    ///      loan against the same deposit.
    function test_ReplayOfSameXrplTxIdIsRejected() public {
        _fundController(MINT_AMOUNT);
        PackedUserOperation memory op = _userOp(MINT_AMOUNT);
        bytes memory data = abi.encode(op);
        bytes memory memo = abi.encodePacked(bytes1(0xFE), bytes1(uint8(0)), bytes8(uint64(0)), keccak256(data));
        bytes32 txId = keccak256("xrpl-tx-replay");

        vm.prank(ASSET_MANAGER_FXRP);
        mac.handleMintedFAssets(txId, XRPL_ADDR, MINT_AMOUNT, 0, memo, executor, data);

        _fundController(MINT_AMOUNT);
        vm.prank(ASSET_MANAGER_FXRP);
        vm.expectRevert();
        mac.handleMintedFAssets(txId, XRPL_ADDR, MINT_AMOUNT, 0, memo, executor, data);
    }
}
