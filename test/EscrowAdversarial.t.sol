// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";

/// @dev Test-only hostile currency; production uses LaunchToken, which has none of these powers.
contract AdversarialToken is ERC20 {
    enum Failure {
        None,
        ReturnFalse,
        Revert,
        ShortDeposit
    }
    Failure public failure;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackResult;
    bool private callingBack;

    error TokenFailure();

    constructor() ERC20("Test", "TEST") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function setFailure(Failure failure_) external {
        failure = failure_;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackAttempted = false;
        callbackSucceeded = false;
        delete callbackResult;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failure == Failure.ReturnFalse) return false;
        if (failure == Failure.Revert) revert TokenFailure();
        _callback();
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (failure == Failure.ReturnFalse) return false;
        if (failure == Failure.Revert) revert TokenFailure();
        _callback();
        bool result = super.transferFrom(from, to, value);
        if (failure == Failure.ShortDeposit) _burn(to, 1);
        return result;
    }

    function _callback() private {
        if (callbackTarget == address(0) || callingBack) return;
        callingBack = true;
        callbackAttempted = true;
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        callingBack = false;
    }
}

contract EscrowAdversarialTest is Test {
    AdversarialToken private token;
    MilestoneEscrow private escrow;
    address private constant RECIPIENT = address(0xCAFE);
    address private constant ARBITER = address(0xBEEF);
    uint256 private deadline;

    function setUp() public {
        vm.warp(1_000);
        deadline = 2_000;
        token = new AdversarialToken();
        escrow = new MilestoneEscrow(address(token));
        token.approve(address(escrow), 1_000 ether);
    }

    function _open(address recipient, address arbiter) private returns (uint256) {
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory deadlines = new uint256[](2);
        amounts[0] = 10 ether;
        amounts[1] = 20 ether;
        deadlines[0] = deadline;
        deadlines[1] = deadline;
        return escrow.openEscrow(recipient, arbiter, amounts, deadlines);
    }

    function _approve(uint256 id, uint256 index) private {
        vm.prank(ARBITER);
        escrow.approveMilestone(id, index);
    }

    function _assertLocked(uint256 id, uint256 locked) private view {
        assertEq(escrow.getEscrow(id).remainingAmount, locked);
        assertEq(escrow.totalLocked(), locked);
        assertEq(token.balanceOf(address(escrow)), locked);
    }

    function _expectFailure(uint256 mode) private {
        if (mode == 1) {
            vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        } else {
            vm.expectRevert(AdversarialToken.TokenFailure.selector);
        }
    }

    function testDepositFailureRollsBackEscrowIdBalancesAndAllowance() public {
        for (uint256 mode = 1; mode <= 3; ++mode) {
            uint256 balance = token.balanceOf(address(this));
            uint256 allowance = token.allowance(address(this), address(escrow));
            token.setFailure(AdversarialToken.Failure(mode));
            if (mode == 3) vm.expectRevert(MilestoneEscrow.IncorrectDepositAmount.selector);
            else _expectFailure(mode);
            _open(RECIPIENT, ARBITER);
            assertEq(escrow.escrowCount(), 0);
            assertEq(escrow.totalLocked(), 0);
            assertEq(token.balanceOf(address(escrow)), 0);
            assertEq(token.balanceOf(address(this)), balance);
            assertEq(token.allowance(address(this), address(escrow)), allowance);
        }
        token.setFailure(AdversarialToken.Failure.None);
        assertEq(_open(RECIPIENT, ARBITER), 1);
        _assertLocked(1, 30 ether);
    }

    function testClaimFailureRetainsApprovalAndCanBeRetried() public {
        uint256 id = _open(RECIPIENT, ARBITER);
        _approve(id, 0);
        for (uint256 mode = 1; mode <= 2; ++mode) {
            token.setFailure(AdversarialToken.Failure(mode));
            _expectFailure(mode);
            vm.prank(RECIPIENT);
            escrow.claimMilestone(id, 0);
            assertEq(uint256(escrow.getMilestone(id, 0).status), uint256(MilestoneEscrow.MilestoneStatus.Approved));
            assertEq(token.balanceOf(RECIPIENT), 0);
            _assertLocked(id, 30 ether);
        }
        token.setFailure(AdversarialToken.Failure.None);
        vm.prank(RECIPIENT);
        escrow.claimMilestone(id, 0);
        assertEq(token.balanceOf(RECIPIENT), 10 ether);
        _assertLocked(id, 20 ether);
    }

    function testReclaimFailureRetainsPendingAndCanBeRetried() public {
        uint256 id = _open(RECIPIENT, ARBITER);
        vm.warp(deadline + 1);
        uint256 balance = token.balanceOf(address(this));
        for (uint256 mode = 1; mode <= 2; ++mode) {
            token.setFailure(AdversarialToken.Failure(mode));
            _expectFailure(mode);
            escrow.reclaimMilestone(id, 1);
            assertEq(uint256(escrow.getMilestone(id, 1).status), uint256(MilestoneEscrow.MilestoneStatus.Pending));
            assertEq(token.balanceOf(address(this)), balance);
            _assertLocked(id, 30 ether);
        }
        token.setFailure(AdversarialToken.Failure.None);
        escrow.reclaimMilestone(id, 1);
        assertEq(token.balanceOf(address(this)), balance + 20 ether);
        _assertLocked(id, 10 ether);
    }

    function testCancelFailureRollsBackEveryRefundAndCancellationFlag() public {
        uint256 id = _open(RECIPIENT, ARBITER);
        uint256 balance = token.balanceOf(address(this));
        for (uint256 mode = 1; mode <= 2; ++mode) {
            token.setFailure(AdversarialToken.Failure(mode));
            _expectFailure(mode);
            vm.prank(ARBITER);
            escrow.cancelEscrow(id);
            assertFalse(escrow.getEscrow(id).cancelled);
            for (uint256 i; i < 2; ++i) {
                assertEq(uint256(escrow.getMilestone(id, i).status), uint256(MilestoneEscrow.MilestoneStatus.Pending));
            }
            assertEq(token.balanceOf(address(this)), balance);
            _assertLocked(id, 30 ether);
        }
        token.setFailure(AdversarialToken.Failure.None);
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);
        assertEq(token.balanceOf(address(this)), balance + 30 ether);
        _assertLocked(id, 0);
    }

    function _assertCallbackBlocked() private view {
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function testDepositCallbackCannotApproveUnfundedMilestone() public {
        token.setCallback(address(escrow), abi.encodeCall(escrow.approveMilestone, (1, 0)));
        uint256 id = _open(RECIPIENT, address(token));
        _assertCallbackBlocked();
        assertEq(uint256(escrow.getMilestone(id, 0).status), uint256(MilestoneEscrow.MilestoneStatus.Pending));
        _assertLocked(id, 30 ether);
    }

    function testClaimCallbackCannotClaimAnotherApprovedMilestone() public {
        uint256 id = _open(address(token), ARBITER);
        _approve(id, 0);
        _approve(id, 1);
        token.setCallback(address(escrow), abi.encodeCall(escrow.claimMilestone, (id, 1)));
        vm.prank(address(token));
        escrow.claimMilestone(id, 0);
        _assertCallbackBlocked();
        assertEq(uint256(escrow.getMilestone(id, 1).status), uint256(MilestoneEscrow.MilestoneStatus.Approved));
        assertEq(token.balanceOf(address(token)), 10 ether);
        _assertLocked(id, 20 ether);
    }

    function testReclaimCallbackCannotReclaimAnotherPendingMilestone() public {
        token.transfer(address(token), 30 ether);
        vm.startPrank(address(token));
        token.approve(address(escrow), 30 ether);
        uint256 id = _open(RECIPIENT, ARBITER);
        vm.stopPrank();
        vm.warp(deadline + 1);
        token.setCallback(address(escrow), abi.encodeCall(escrow.reclaimMilestone, (id, 1)));
        vm.prank(address(token));
        escrow.reclaimMilestone(id, 0);
        _assertCallbackBlocked();
        assertEq(uint256(escrow.getMilestone(id, 1).status), uint256(MilestoneEscrow.MilestoneStatus.Pending));
        assertEq(token.balanceOf(address(token)), 10 ether);
        _assertLocked(id, 20 ether);
    }

    function testCancelCallbackCannotCancelAnotherEscrow() public {
        uint256 first = _open(RECIPIENT, address(token));
        uint256 second = _open(RECIPIENT, address(token));
        token.setCallback(address(escrow), abi.encodeCall(escrow.cancelEscrow, (second)));
        vm.prank(address(token));
        escrow.cancelEscrow(first);
        _assertCallbackBlocked();
        assertFalse(escrow.getEscrow(second).cancelled);
        _assertLocked(second, 30 ether);
    }

    function testPayoutCallbackCannotOpenAnotherEscrow() public {
        uint256 id = _open(RECIPIENT, ARBITER);
        token.transfer(address(token), 1 ether);
        vm.prank(address(token));
        token.approve(address(escrow), 1 ether);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory deadlines = new uint256[](1);
        amounts[0] = 1 ether;
        deadlines[0] = deadline;
        token.setCallback(address(escrow), abi.encodeCall(escrow.openEscrow, (RECIPIENT, ARBITER, amounts, deadlines)));
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);
        _assertCallbackBlocked();
        assertEq(escrow.escrowCount(), 1);
        _assertLocked(id, 0);
    }
}
