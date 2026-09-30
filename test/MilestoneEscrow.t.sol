// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";

contract MilestoneEscrowTest is Test {
    LaunchToken internal token;
    MilestoneEscrow internal escrow;

    address internal constant FUNDER = address(0xF001);
    address internal constant SECOND_FUNDER = address(0xF002);
    address internal constant RECIPIENT = address(0xB001);
    address internal constant SECOND_RECIPIENT = address(0xB002);
    address internal constant ARBITER = address(0xA001);
    address internal constant SECOND_ARBITER = address(0xA002);
    address internal constant STRANGER = address(0xBAD);
    uint256 internal constant INITIAL_FUNDS = 1_000_000 ether;

    function setUp() public {
        vm.warp(100 days);
        token = new LaunchToken();
        escrow = new MilestoneEscrow(address(token));
        token.transfer(FUNDER, INITIAL_FUNDS);
        token.transfer(SECOND_FUNDER, INITIAL_FUNDS);
    }

    function test_constructorConfiguresCurrencyWithoutMovingTokens() public view {
        assertEq(address(escrow.token()), address(token));
        assertEq(escrow.MAX_MILESTONES(), 5);
        assertEq(escrow.escrowCount(), 0);
        assertEq(escrow.totalLocked(), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_constructorRejectsZeroAndNoncontractToken() public {
        vm.expectRevert(MilestoneEscrow.InvalidToken.selector);
        new MilestoneEscrow(address(0));
        vm.expectRevert(MilestoneEscrow.InvalidToken.selector);
        new MilestoneEscrow(STRANGER);
    }

    function test_openEscrowDepositsEntireAmountAndStoresAllTerms() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(5);
        uint256 total = _sum(amounts);
        uint256 id = _open(FUNDER, RECIPIENT, ARBITER, amounts, deadlines);

        assertEq(id, 1);
        assertEq(escrow.escrowCount(), 1);
        MilestoneEscrow.Escrow memory data = escrow.getEscrow(id);
        assertEq(data.funder, FUNDER);
        assertEq(data.recipient, RECIPIENT);
        assertEq(data.arbiter, ARBITER);
        assertEq(data.totalAmount, total);
        assertEq(data.remainingAmount, total);
        assertFalse(data.cancelled);
        assertEq(data.milestones.length, 5);
        for (uint256 i; i < amounts.length; ++i) {
            assertEq(data.milestones[i].amount, amounts[i]);
            assertEq(data.milestones[i].deadline, deadlines[i]);
            _assertStatus(id, i, MilestoneEscrow.MilestoneStatus.Pending);
        }
        assertEq(token.allowance(FUNDER, address(escrow)), 0);
        _assertAccounting(id, total, 0, 0);
    }

    function test_deadlinesMayBeUnorderedAndEqual() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(3);
        deadlines[0] = block.timestamp + 30 days;
        deadlines[1] = block.timestamp + 1 days;
        deadlines[2] = deadlines[1];
        uint256 id = _open(FUNDER, RECIPIENT, ARBITER, amounts, deadlines);

        vm.warp(deadlines[1] + 1);
        vm.prank(FUNDER);
        escrow.reclaimMilestone(id, 1);
        vm.prank(ARBITER);
        escrow.approveMilestone(id, 0);
        _assertStatus(id, 0, MilestoneEscrow.MilestoneStatus.Approved);
        _assertStatus(id, 2, MilestoneEscrow.MilestoneStatus.Pending);
        _assertAccounting(id, _sum(amounts), 0, amounts[1]);
    }

    function test_openRejectsZeroAndMoreThanFiveMilestones() public {
        bytes memory expected = abi.encodeWithSelector(MilestoneEscrow.InvalidMilestoneCount.selector);
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(0);
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, deadlines, expected);
        (amounts, deadlines) = _terms(6);
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, deadlines, expected);
    }

    function test_openRejectsMismatchedArrayLengths() public {
        bytes memory expected = abi.encodeWithSelector(MilestoneEscrow.ArrayLengthMismatch.selector);
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(2);
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, new uint256[](1), expected);
        _expectInvalidOpen(RECIPIENT, ARBITER, new uint256[](1), deadlines, expected);
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, new uint256[](0), expected);
    }

    function test_openRejectsZeroAmountIncludingLaterMilestone() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(3);
        amounts[2] = 0;
        bytes memory expected = abi.encodeWithSelector(MilestoneEscrow.InvalidAmount.selector, 2);
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, deadlines, expected);
        amounts[0] = 0;
        expected = abi.encodeWithSelector(MilestoneEscrow.InvalidAmount.selector, 0);
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, deadlines, expected);
    }

    function test_openRejectsDeadlineAtOrBeforeNow() public {
        bytes memory expected = abi.encodeWithSelector(MilestoneEscrow.InvalidDeadline.selector, 1);
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(2);
        deadlines[1] = block.timestamp;
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, deadlines, expected);
        deadlines[1] = block.timestamp - 1;
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, deadlines, expected);
    }

    function test_openRejectsZeroAndEscrowRoleAddresses() public {
        bytes memory expected = abi.encodeWithSelector(MilestoneEscrow.InvalidParty.selector);
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(1);
        _expectInvalidOpen(address(0), ARBITER, amounts, deadlines, expected);
        _expectInvalidOpen(RECIPIENT, address(0), amounts, deadlines, expected);
        _expectInvalidOpen(address(escrow), ARBITER, amounts, deadlines, expected);
        _expectInvalidOpen(RECIPIENT, address(escrow), amounts, deadlines, expected);
    }

    function test_openRejectsTotalOverflowAtomically() public {
        bytes memory expected = stdError.arithmeticError;
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(2);
        amounts[0] = type(uint256).max;
        amounts[1] = 1;
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, deadlines, expected);
    }

    function test_missingAndInsufficientAllowanceDoNotCreateAnEscrow() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(1);
        bytes memory expected =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, amounts[0]);
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, deadlines, expected);
        vm.prank(FUNDER);
        token.approve(address(escrow), amounts[0] - 1);
        expected = abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), amounts[0] - 1, amounts[0]
        );
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, deadlines, expected);
        assertEq(token.allowance(FUNDER, address(escrow)), amounts[0] - 1);
    }

    function test_insufficientBalanceRollsBackAllowanceAndEscrowCreation() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(1);
        amounts[0] = INITIAL_FUNDS + 1;
        bytes memory expected =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, FUNDER, INITIAL_FUNDS, amounts[0]);
        vm.prank(FUNDER);
        token.approve(address(escrow), amounts[0]);
        _expectInvalidOpen(RECIPIENT, ARBITER, amounts, deadlines, expected);
        assertEq(token.allowance(FUNDER, address(escrow)), amounts[0]);
    }

    function test_arbiterApprovalAndRecipientClaimTransferExactAmount() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(2);
        uint256 id = _open(FUNDER, RECIPIENT, ARBITER, amounts, deadlines);
        vm.prank(ARBITER);
        escrow.approveMilestone(id, 0);
        _assertStatus(id, 0, MilestoneEscrow.MilestoneStatus.Approved);
        _assertAccounting(id, _sum(amounts), 0, 0);
        vm.prank(RECIPIENT);
        escrow.claimMilestone(id, 0);
        _assertStatus(id, 0, MilestoneEscrow.MilestoneStatus.Claimed);
        _assertAccounting(id, _sum(amounts), amounts[0], 0);
    }

    function test_onlyNamedArbiterCanApproveOrCancel() public {
        uint256 id = _openDefault();
        address[3] memory callers = [FUNDER, RECIPIENT, STRANGER];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(MilestoneEscrow.Unauthorized.selector);
            escrow.approveMilestone(id, 0);
            vm.prank(callers[i]);
            vm.expectRevert(MilestoneEscrow.Unauthorized.selector);
            escrow.cancelEscrow(id);
        }
        _assertStatus(id, 0, MilestoneEscrow.MilestoneStatus.Pending);
        assertFalse(escrow.getEscrow(id).cancelled);
    }

    function test_onlyNamedRecipientCanClaim() public {
        uint256 id = _openDefault();
        vm.prank(ARBITER);
        escrow.approveMilestone(id, 0);
        address[3] memory callers = [FUNDER, ARBITER, STRANGER];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(MilestoneEscrow.Unauthorized.selector);
            escrow.claimMilestone(id, 0);
        }
        _assertStatus(id, 0, MilestoneEscrow.MilestoneStatus.Approved);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function test_onlyNamedFunderCanReclaim() public {
        uint256 id = _openDefault();
        vm.warp(escrow.getMilestone(id, 0).deadline + 1);
        address[3] memory callers = [RECIPIENT, ARBITER, STRANGER];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(MilestoneEscrow.Unauthorized.selector);
            escrow.reclaimMilestone(id, 0);
        }
        _assertStatus(id, 0, MilestoneEscrow.MilestoneStatus.Pending);
    }

    function test_pendingMilestoneCannotBeClaimed() public {
        uint256 id = _openDefault();
        vm.prank(RECIPIENT);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        escrow.claimMilestone(id, 0);
        _assertStatus(id, 0, MilestoneEscrow.MilestoneStatus.Pending);
    }

    function test_approvalAllowedAtDeadlineButReclaimNotYetAllowed() public {
        uint256 id = _openDefault();
        vm.warp(escrow.getMilestone(id, 0).deadline);
        vm.prank(FUNDER);
        vm.expectRevert(MilestoneEscrow.DeadlineNotPassed.selector);
        escrow.reclaimMilestone(id, 0);
        vm.prank(ARBITER);
        escrow.approveMilestone(id, 0);
        _assertStatus(id, 0, MilestoneEscrow.MilestoneStatus.Approved);
    }

    function test_reclaimAllowedOnlyAfterDeadlineAndApprovalThenForbidden() public {
        uint256 id = _openDefault();
        vm.prank(FUNDER);
        vm.expectRevert(MilestoneEscrow.DeadlineNotPassed.selector);
        escrow.reclaimMilestone(id, 0);
        vm.warp(escrow.getMilestone(id, 0).deadline + 1);
        vm.prank(ARBITER);
        vm.expectRevert(MilestoneEscrow.DeadlinePassed.selector);
        escrow.approveMilestone(id, 0);
        vm.prank(FUNDER);
        escrow.reclaimMilestone(id, 0);
        _assertStatus(id, 0, MilestoneEscrow.MilestoneStatus.Refunded);
        _assertAccounting(id, 100 ether, 0, 100 ether);
    }

    function test_approvalCannotBeRepeatedOrReclaimedAfterDeadline() public {
        uint256 id = _openDefault();
        vm.prank(ARBITER);
        escrow.approveMilestone(id, 0);
        vm.prank(ARBITER);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        escrow.approveMilestone(id, 0);
        vm.warp(escrow.getMilestone(id, 0).deadline + 1);
        vm.prank(FUNDER);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        escrow.reclaimMilestone(id, 0);
        vm.prank(RECIPIENT);
        escrow.claimMilestone(id, 0);
        _assertAccounting(id, 100 ether, 100 ether, 0);
    }

    function test_claimedMilestoneCannotBePaidAgainOrApprovedOrReclaimed() public {
        uint256 id = _openDefault();
        vm.prank(ARBITER);
        escrow.approveMilestone(id, 0);
        vm.prank(RECIPIENT);
        escrow.claimMilestone(id, 0);
        vm.prank(RECIPIENT);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        escrow.claimMilestone(id, 0);
        vm.prank(ARBITER);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        escrow.approveMilestone(id, 0);
        vm.warp(escrow.getMilestone(id, 0).deadline + 1);
        vm.prank(FUNDER);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        escrow.reclaimMilestone(id, 0);
        _assertAccounting(id, 100 ether, 100 ether, 0);
    }

    function test_refundedMilestoneCannotBeRefundedOrClaimedOrApprovedAgain() public {
        uint256 id = _openDefault();
        vm.warp(escrow.getMilestone(id, 0).deadline + 1);
        vm.prank(FUNDER);
        escrow.reclaimMilestone(id, 0);
        vm.prank(FUNDER);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        escrow.reclaimMilestone(id, 0);
        vm.prank(RECIPIENT);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        escrow.claimMilestone(id, 0);
        vm.prank(ARBITER);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        escrow.approveMilestone(id, 0);
        _assertAccounting(id, 100 ether, 0, 100 ether);
    }

    function test_cancelImmediatelyRefundsEveryPendingMilestone() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(5);
        uint256 id = _open(FUNDER, RECIPIENT, ARBITER, amounts, deadlines);
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);
        assertTrue(escrow.getEscrow(id).cancelled);
        for (uint256 i; i < amounts.length; ++i) {
            _assertStatus(id, i, MilestoneEscrow.MilestoneStatus.Refunded);
        }
        _assertAccounting(id, _sum(amounts), 0, _sum(amounts));
    }

    function test_cancelMixedStatesReturnsOnlyPendingAndPreservesApprovedClaims() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(5);
        uint256 id = _open(FUNDER, RECIPIENT, ARBITER, amounts, deadlines);
        vm.startPrank(ARBITER);
        escrow.approveMilestone(id, 0);
        escrow.approveMilestone(id, 1);
        vm.stopPrank();
        vm.prank(RECIPIENT);
        escrow.claimMilestone(id, 0);
        vm.warp(deadlines[3] + 1);
        vm.prank(FUNDER);
        escrow.reclaimMilestone(id, 2);
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);

        _assertStatus(id, 0, MilestoneEscrow.MilestoneStatus.Claimed);
        _assertStatus(id, 1, MilestoneEscrow.MilestoneStatus.Approved);
        for (uint256 i = 2; i < amounts.length; ++i) {
            _assertStatus(id, i, MilestoneEscrow.MilestoneStatus.Refunded);
        }
        uint256 refunded = amounts[2] + amounts[3] + amounts[4];
        _assertAccounting(id, _sum(amounts), amounts[0], refunded);
        vm.warp(deadlines[4] + 365 days);
        vm.prank(RECIPIENT);
        escrow.claimMilestone(id, 1);
        _assertAccounting(id, _sum(amounts), amounts[0] + amounts[1], refunded);
    }

    function test_cancelWithOnlyApprovedMilestonesKeepsAllFundsClaimable() public {
        uint256 id = _openDefault();
        vm.prank(ARBITER);
        escrow.approveMilestone(id, 0);
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);
        assertTrue(escrow.getEscrow(id).cancelled);
        _assertAccounting(id, 100 ether, 0, 0);
        vm.prank(RECIPIENT);
        escrow.claimMilestone(id, 0);
        _assertAccounting(id, 100 ether, 100 ether, 0);
    }

    function test_cancelledEscrowRejectsRepeatedCancellationAndFurtherApproval() public {
        uint256 id = _openDefault();
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);
        vm.prank(ARBITER);
        vm.expectRevert(MilestoneEscrow.EscrowCancelled.selector);
        escrow.cancelEscrow(id);
        vm.prank(ARBITER);
        vm.expectRevert(MilestoneEscrow.EscrowCancelled.selector);
        escrow.approveMilestone(id, 0);
        vm.prank(RECIPIENT);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        escrow.claimMilestone(id, 0);
        vm.warp(escrow.getMilestone(id, 0).deadline + 1);
        vm.prank(FUNDER);
        vm.expectRevert(MilestoneEscrow.InvalidMilestoneStatus.selector);
        escrow.reclaimMilestone(id, 0);
        _assertAccounting(id, 100 ether, 0, 100 ether);
    }

    function test_completedEscrowCanBeCancelledWithoutAnotherTransfer() public {
        uint256 id = _openDefault();
        vm.prank(ARBITER);
        escrow.approveMilestone(id, 0);
        vm.prank(RECIPIENT);
        escrow.claimMilestone(id, 0);
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);
        assertTrue(escrow.getEscrow(id).cancelled);
        _assertAccounting(id, 100 ether, 100 ether, 0);
    }

    function test_unknownIdsAndOutOfBoundsIndexesCannotBeReadOrMutated() public {
        uint256 id = _openDefault();
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.EscrowNotFound.selector, 0));
        escrow.getEscrow(0);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.EscrowNotFound.selector, id + 1));
        escrow.getEscrow(id + 1);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.EscrowNotFound.selector, 0));
        escrow.getMilestone(0, 0);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneNotFound.selector, 1));
        escrow.getMilestone(id, 1);
        vm.prank(ARBITER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.EscrowNotFound.selector, id + 1));
        escrow.approveMilestone(id + 1, 0);
        vm.prank(ARBITER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneNotFound.selector, 1));
        escrow.approveMilestone(id, 1);
        vm.prank(RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneNotFound.selector, 1));
        escrow.claimMilestone(id, 1);
        vm.prank(FUNDER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneNotFound.selector, 1));
        escrow.reclaimMilestone(id, 1);
        vm.prank(ARBITER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.EscrowNotFound.selector, id + 1));
        escrow.cancelEscrow(id + 1);
        _assertAccounting(id, 100 ether, 0, 0);
    }

    function test_multipleEscrowsKeepBalancesPermissionsAndTermsSeparate() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(2);
        uint256 first = _open(FUNDER, RECIPIENT, ARBITER, amounts, deadlines);
        uint256 second = _open(SECOND_FUNDER, SECOND_RECIPIENT, SECOND_ARBITER, amounts, deadlines);
        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(escrow.escrowCount(), 2);
        vm.prank(ARBITER);
        vm.expectRevert(MilestoneEscrow.Unauthorized.selector);
        escrow.approveMilestone(second, 0);
        vm.prank(ARBITER);
        escrow.approveMilestone(first, 0);
        vm.prank(RECIPIENT);
        escrow.claimMilestone(first, 0);
        vm.prank(SECOND_ARBITER);
        escrow.cancelEscrow(second);
        assertEq(token.balanceOf(SECOND_FUNDER), INITIAL_FUNDS);
        assertEq(token.balanceOf(SECOND_RECIPIENT), 0);
        assertEq(escrow.getEscrow(second).remainingAmount, 0);
        assertEq(escrow.getEscrow(first).remainingAmount, amounts[1]);
        assertEq(escrow.totalLocked(), amounts[1]);
        assertEq(token.balanceOf(address(escrow)), amounts[1]);
        vm.warp(deadlines[1] + 1);
        vm.prank(FUNDER);
        escrow.reclaimMilestone(first, 1);
        assertEq(token.balanceOf(FUNDER), INITIAL_FUNDS - amounts[0]);
        assertEq(token.balanceOf(RECIPIENT), amounts[0]);
        assertEq(escrow.totalLocked(), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_rolesMayOverlapWhenFunderExplicitlyChoosesThem() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(1);
        uint256 id = _open(FUNDER, FUNDER, FUNDER, amounts, deadlines);
        vm.startPrank(FUNDER);
        escrow.approveMilestone(id, 0);
        escrow.claimMilestone(id, 0);
        vm.stopPrank();
        assertEq(token.balanceOf(FUNDER), INITIAL_FUNDS);
        assertEq(escrow.totalLocked(), 0);
        assertEq(escrow.getEscrow(id).remainingAmount, 0);
    }

    function test_directTokenDonationDoesNotIncreaseUserEntitlements() public {
        uint256 id = _openDefault();
        token.transfer(address(escrow), 7 ether);
        assertEq(escrow.totalLocked(), 100 ether);
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);
        assertEq(token.balanceOf(FUNDER), INITIAL_FUNDS);
        assertEq(token.balanceOf(address(escrow)), 7 ether);
        assertEq(escrow.totalLocked(), 0);
    }

    function test_openEmitsPartiesAndEveryMilestoneForIndexers() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(2);
        vm.prank(FUNDER);
        token.approve(address(escrow), _sum(amounts));
        vm.expectEmit(true, true, true, true, address(escrow));
        emit MilestoneEscrow.EscrowOpened(1, FUNDER, RECIPIENT, ARBITER, _sum(amounts), 2);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit MilestoneEscrow.MilestoneCreated(1, 0, amounts[0], deadlines[0]);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit MilestoneEscrow.MilestoneCreated(1, 1, amounts[1], deadlines[1]);
        vm.prank(FUNDER);
        escrow.openEscrow(RECIPIENT, ARBITER, amounts, deadlines);
    }

    function test_settlementEmitsApprovalPayoutRefundAndCancellationEvents() public {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(3);
        uint256 id = _open(FUNDER, RECIPIENT, ARBITER, amounts, deadlines);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit MilestoneEscrow.MilestoneApproved(id, 0);
        vm.prank(ARBITER);
        escrow.approveMilestone(id, 0);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit MilestoneEscrow.MilestoneClaimed(id, 0, RECIPIENT, amounts[0]);
        vm.prank(RECIPIENT);
        escrow.claimMilestone(id, 0);

        vm.warp(deadlines[1] + 1);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit MilestoneEscrow.MilestoneRefunded(id, 1, FUNDER, amounts[1]);
        vm.prank(FUNDER);
        escrow.reclaimMilestone(id, 1);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit MilestoneEscrow.MilestoneRefunded(id, 2, FUNDER, amounts[2]);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit MilestoneEscrow.EscrowCanceled(id, amounts[2]);
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);
    }

    function testFuzz_lifecycleConservesEveryToken(
        uint256 seed,
        uint8 rawCount,
        uint8 approvedMask,
        uint8 earlyClaimMask,
        bool cancel
    ) public {
        uint256 count = bound(uint256(rawCount), 1, 5);
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(count);
        for (uint256 i; i < count; ++i) {
            amounts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, 1_000 ether);
        }
        uint256 total = _sum(amounts);
        uint256 id = _open(FUNDER, RECIPIENT, ARBITER, amounts, deadlines);
        uint256 claimed;
        uint256 refunded;
        for (uint256 i; i < count; ++i) {
            if ((uint256(approvedMask) & (1 << i)) != 0) {
                vm.prank(ARBITER);
                escrow.approveMilestone(id, i);
                if ((uint256(earlyClaimMask) & (1 << i)) != 0) {
                    vm.prank(RECIPIENT);
                    escrow.claimMilestone(id, i);
                    claimed += amounts[i];
                }
            }
            _assertAccounting(id, total, claimed, refunded);
        }

        vm.warp(deadlines[count - 1] + 1);
        if (cancel) {
            for (uint256 i; i < count; ++i) {
                if ((uint256(approvedMask) & (1 << i)) == 0) refunded += amounts[i];
            }
            vm.prank(ARBITER);
            escrow.cancelEscrow(id);
            _assertAccounting(id, total, claimed, refunded);
        }
        // Settle in reverse order to exercise independent milestone state.
        for (uint256 n = count; n > 0; --n) {
            uint256 i = n - 1;
            if ((uint256(approvedMask) & (1 << i)) != 0) {
                if ((uint256(earlyClaimMask) & (1 << i)) == 0) {
                    vm.prank(RECIPIENT);
                    escrow.claimMilestone(id, i);
                    claimed += amounts[i];
                }
                _assertStatus(id, i, MilestoneEscrow.MilestoneStatus.Claimed);
            } else {
                if (!cancel) {
                    vm.prank(FUNDER);
                    escrow.reclaimMilestone(id, i);
                    refunded += amounts[i];
                }
                _assertStatus(id, i, MilestoneEscrow.MilestoneStatus.Refunded);
            }
            _assertAccounting(id, total, claimed, refunded);
        }
        assertEq(claimed + refunded, total);
        assertEq(escrow.totalLocked(), 0);
    }

    function _terms(uint256 count) internal view returns (uint256[] memory amounts, uint256[] memory deadlines) {
        amounts = new uint256[](count);
        deadlines = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            amounts[i] = (i + 1) * 100 ether;
            deadlines[i] = block.timestamp + (i + 1) * 1 days;
        }
    }

    function _sum(uint256[] memory amounts) internal pure returns (uint256 total) {
        for (uint256 i; i < amounts.length; ++i) {
            total += amounts[i];
        }
    }

    function _open(
        address funder,
        address recipient,
        address arbiter,
        uint256[] memory amounts,
        uint256[] memory deadlines
    ) internal returns (uint256 id) {
        vm.startPrank(funder);
        token.approve(address(escrow), _sum(amounts));
        id = escrow.openEscrow(recipient, arbiter, amounts, deadlines);
        vm.stopPrank();
    }

    function _openDefault() internal returns (uint256 id) {
        (uint256[] memory amounts, uint256[] memory deadlines) = _terms(1);
        return _open(FUNDER, RECIPIENT, ARBITER, amounts, deadlines);
    }

    function _expectInvalidOpen(
        address recipient,
        address arbiter,
        uint256[] memory amounts,
        uint256[] memory deadlines,
        bytes memory expected
    ) internal {
        vm.prank(FUNDER);
        vm.expectRevert(expected);
        escrow.openEscrow(recipient, arbiter, amounts, deadlines);
        assertEq(escrow.escrowCount(), 0);
        assertEq(escrow.totalLocked(), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(FUNDER), INITIAL_FUNDS);
    }

    function _assertStatus(uint256 id, uint256 index, MilestoneEscrow.MilestoneStatus expected) internal view {
        assertEq(uint256(escrow.getMilestone(id, index).status), uint256(expected));
    }

    function _assertAccounting(uint256 id, uint256 deposited, uint256 claimed, uint256 refunded) internal view {
        uint256 outstanding = deposited - claimed - refunded;
        MilestoneEscrow.Escrow memory data = escrow.getEscrow(id);
        uint256 pendingOrApproved;
        for (uint256 i; i < data.milestones.length; ++i) {
            MilestoneEscrow.Milestone memory milestone = data.milestones[i];
            if (
                milestone.status == MilestoneEscrow.MilestoneStatus.Pending
                    || milestone.status == MilestoneEscrow.MilestoneStatus.Approved
            ) pendingOrApproved += milestone.amount;
        }
        assertEq(data.totalAmount, deposited);
        assertEq(data.remainingAmount, outstanding);
        assertEq(pendingOrApproved, outstanding);
        assertEq(escrow.totalLocked(), outstanding);
        assertEq(token.balanceOf(address(escrow)), outstanding);
        assertEq(token.balanceOf(FUNDER), INITIAL_FUNDS - deposited + refunded);
        assertEq(token.balanceOf(RECIPIENT), claimed);
        assertEq(token.balanceOf(ARBITER), 0);
        assertEq(token.balanceOf(STRANGER), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
