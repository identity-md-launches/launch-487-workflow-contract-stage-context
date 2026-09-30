// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MilestoneEscrow
/// @notice Fully funded MILE milestones with immutable parties and no administrative powers.
/// @dev Deploy only with the project's fixed-supply LaunchToken. Deadlines use Unix seconds.
contract MilestoneEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_MILESTONES = 5;
    IERC20 public immutable token;
    uint256 public escrowCount;
    /// @notice Outstanding principal across all escrows, including approved unclaimed amounts.
    uint256 public totalLocked;

    enum MilestoneStatus {
        Pending,
        Approved,
        Claimed,
        Refunded
    }

    struct Milestone {
        uint256 amount;
        uint256 deadline;
        MilestoneStatus status;
    }

    struct Escrow {
        address funder;
        address recipient;
        address arbiter;
        uint256 totalAmount;
        uint256 remainingAmount;
        bool cancelled;
        Milestone[] milestones;
    }

    mapping(uint256 escrowId => Escrow) private _escrows;

    error InvalidToken();
    error InvalidParty();
    error InvalidMilestoneCount();
    error ArrayLengthMismatch();
    error InvalidAmount(uint256 milestoneIndex);
    error InvalidDeadline(uint256 milestoneIndex);
    error EscrowNotFound(uint256 escrowId);
    error MilestoneNotFound(uint256 milestoneIndex);
    error Unauthorized();
    error EscrowCancelled();
    error InvalidMilestoneStatus();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error IncorrectDepositAmount();

    event EscrowOpened(
        uint256 indexed escrowId,
        address indexed funder,
        address indexed recipient,
        address arbiter,
        uint256 totalAmount,
        uint256 milestoneCount
    );
    event MilestoneCreated(uint256 indexed escrowId, uint256 indexed milestoneIndex, uint256 amount, uint256 deadline);
    event MilestoneApproved(uint256 indexed escrowId, uint256 indexed milestoneIndex);
    event MilestoneClaimed(
        uint256 indexed escrowId, uint256 indexed milestoneIndex, address indexed recipient, uint256 amount
    );
    event MilestoneRefunded(
        uint256 indexed escrowId, uint256 indexed milestoneIndex, address indexed funder, uint256 amount
    );
    event EscrowCanceled(uint256 indexed escrowId, uint256 refundedAmount);

    /// @param token_ The already deployed LaunchToken address (manifest reference: $token).
    /// @dev No token movement, owner assignment or initialization calls at deployment.
    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = IERC20(token_);
    }

    /// @notice Deposit the full sum and create between one and five independent milestones.
    /// @dev Caller is the funder. Amounts are MILE minor units; deadlines must be strictly future.
    function openEscrow(address recipient, address arbiter, uint256[] calldata amounts, uint256[] calldata deadlines)
        external
        nonReentrant
        returns (uint256 escrowId)
    {
        if (recipient == address(0) || arbiter == address(0) || recipient == address(this) || arbiter == address(this))
        {
            revert InvalidParty();
        }
        uint256 count = amounts.length;
        if (count == 0 || count > MAX_MILESTONES) revert InvalidMilestoneCount();
        if (count != deadlines.length) revert ArrayLengthMismatch();

        uint256 total;
        for (uint256 i; i < count; ++i) {
            if (amounts[i] == 0) revert InvalidAmount(i);
            if (deadlines[i] <= block.timestamp) revert InvalidDeadline(i);
            total += amounts[i];
        }

        escrowId = ++escrowCount;
        Escrow storage escrow = _escrows[escrowId];
        escrow.funder = msg.sender;
        escrow.recipient = recipient;
        escrow.arbiter = arbiter;
        escrow.totalAmount = total;
        escrow.remainingAmount = total;
        totalLocked += total;

        emit EscrowOpened(escrowId, msg.sender, recipient, arbiter, total, count);
        for (uint256 i; i < count; ++i) {
            escrow.milestones.push(Milestone(amounts[i], deadlines[i], MilestoneStatus.Pending));
            emit MilestoneCreated(escrowId, i, amounts[i], deadlines[i]);
        }

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), total);
        if (token.balanceOf(address(this)) != balanceBefore + total) revert IncorrectDepositAmount();
    }

    /// @notice The named arbiter may irrevocably approve a pending milestone through its deadline.
    function approveMilestone(uint256 escrowId, uint256 milestoneIndex) external nonReentrant {
        Escrow storage escrow = _getEscrow(escrowId);
        if (msg.sender != escrow.arbiter) revert Unauthorized();
        if (escrow.cancelled) revert EscrowCancelled();
        Milestone storage milestone = _getMilestone(escrow, milestoneIndex);
        if (milestone.status != MilestoneStatus.Pending) revert InvalidMilestoneStatus();
        if (block.timestamp > milestone.deadline) revert DeadlinePassed();
        milestone.status = MilestoneStatus.Approved;
        emit MilestoneApproved(escrowId, milestoneIndex);
    }

    /// @notice Only the named recipient may claim; approval survives deadline expiry and cancellation.
    function claimMilestone(uint256 escrowId, uint256 milestoneIndex) external nonReentrant {
        Escrow storage escrow = _getEscrow(escrowId);
        if (msg.sender != escrow.recipient) revert Unauthorized();
        Milestone storage milestone = _getMilestone(escrow, milestoneIndex);
        if (milestone.status != MilestoneStatus.Approved) revert InvalidMilestoneStatus();
        milestone.status = MilestoneStatus.Claimed;
        escrow.remainingAmount -= milestone.amount;
        totalLocked -= milestone.amount;
        emit MilestoneClaimed(escrowId, milestoneIndex, escrow.recipient, milestone.amount);
        token.safeTransfer(escrow.recipient, milestone.amount);
    }

    /// @notice Only the funder may refund a pending milestone, strictly after its deadline.
    function reclaimMilestone(uint256 escrowId, uint256 milestoneIndex) external nonReentrant {
        Escrow storage escrow = _getEscrow(escrowId);
        if (msg.sender != escrow.funder) revert Unauthorized();
        Milestone storage milestone = _getMilestone(escrow, milestoneIndex);
        if (milestone.status != MilestoneStatus.Pending) revert InvalidMilestoneStatus();
        if (block.timestamp <= milestone.deadline) revert DeadlineNotPassed();
        milestone.status = MilestoneStatus.Refunded;
        escrow.remainingAmount -= milestone.amount;
        totalLocked -= milestone.amount;
        emit MilestoneRefunded(escrowId, milestoneIndex, escrow.funder, milestone.amount);
        token.safeTransfer(escrow.funder, milestone.amount);
    }

    /// @notice Arbiter cancels once and returns every pending milestone to the funder in one transfer.
    /// @dev Approved amounts remain owed to the recipient; already settled amounts never move again.
    function cancelEscrow(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = _getEscrow(escrowId);
        if (msg.sender != escrow.arbiter) revert Unauthorized();
        if (escrow.cancelled) revert EscrowCancelled();
        escrow.cancelled = true;

        uint256 refund;
        for (uint256 i; i < escrow.milestones.length; ++i) {
            Milestone storage milestone = escrow.milestones[i];
            if (milestone.status == MilestoneStatus.Pending) {
                milestone.status = MilestoneStatus.Refunded;
                refund += milestone.amount;
                emit MilestoneRefunded(escrowId, i, escrow.funder, milestone.amount);
            }
        }
        escrow.remainingAmount -= refund;
        totalLocked -= refund;
        emit EscrowCanceled(escrowId, refund);
        if (refund != 0) token.safeTransfer(escrow.funder, refund);
    }

    /// @notice Complete bounded snapshot; IDs are contiguous from 1 through escrowCount.
    function getEscrow(uint256 escrowId) external view returns (Escrow memory) {
        return _getEscrow(escrowId);
    }

    function getMilestone(uint256 escrowId, uint256 milestoneIndex) external view returns (Milestone memory) {
        return _getMilestone(_getEscrow(escrowId), milestoneIndex);
    }

    function _getEscrow(uint256 escrowId) private view returns (Escrow storage escrow) {
        escrow = _escrows[escrowId];
        if (escrow.funder == address(0)) revert EscrowNotFound(escrowId);
    }

    function _getMilestone(Escrow storage escrow, uint256 milestoneIndex)
        private
        view
        returns (Milestone storage milestone)
    {
        if (milestoneIndex >= escrow.milestones.length) revert MilestoneNotFound(milestoneIndex);
        return escrow.milestones[milestoneIndex];
    }
}
