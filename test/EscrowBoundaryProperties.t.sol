// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MilestoneEscrow} from "src/MilestoneEscrow.sol";

/// forge-config: default.fuzz.runs = 1000
contract EscrowBoundaryPropertiesTest is Test {
    uint256 private constant SUPPLY = 1e27;
    address private constant RECIPIENT = address(0xCA11);
    address private constant ARBITER = address(0xAB17);
    LaunchToken private token;
    MilestoneEscrow private escrow;

    function setUp() public {
        vm.warp(1_900_000_000);
        token = new LaunchToken();
        escrow = new MilestoneEscrow(address(token));
    }

    function test_oneMinorUnitClaim() public {
        _roundTrip(1, 0);
    }

    function test_oneMinorUnitReclaim() public {
        _roundTrip(1, 1);
    }

    function test_oneMinorUnitCancel() public {
        _roundTrip(1, 2);
    }

    function test_entireSupplyClaim() public {
        _roundTrip(SUPPLY, 0);
    }

    function test_entireSupplyReclaim() public {
        _roundTrip(SUPPLY, 1);
    }

    function test_entireSupplyCancel() public {
        _roundTrip(SUPPLY, 2);
    }

    function testFuzz_roundTripHasNoFeesOrRounding(uint256 amount, uint256 outcome) public {
        _roundTrip(bound(amount, 1, SUPPLY), outcome % 3);
    }

    function _roundTrip(uint256 amount, uint256 outcome) private {
        uint256 deadline = block.timestamp + 1;
        uint256 id = _openOne(amount, deadline);
        assertEq(token.balanceOf(address(escrow)), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.allowance(address(this), address(escrow)), 0);

        if (outcome == 0) {
            vm.prank(ARBITER);
            escrow.approveMilestone(id, 0);
            vm.warp(deadline + 365 days);
            vm.prank(RECIPIENT);
            escrow.claimMilestone(id, 0);
        } else if (outcome == 1) {
            vm.warp(deadline + 1);
            escrow.reclaimMilestone(id, 0);
        } else {
            vm.prank(ARBITER);
            escrow.cancelEscrow(id);
        }
        assertEq(token.balanceOf(address(this)), outcome == 0 ? SUPPLY - amount : SUPPLY);
        assertEq(token.balanceOf(RECIPIENT), outcome == 0 ? amount : 0);
        assertEq(token.balanceOf(ARBITER), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalLocked(), 0);
        assertEq(escrow.getEscrow(id).remainingAmount, 0);
        assertEq(uint256(escrow.getMilestone(id, 0).status), outcome == 0 ? 2 : 3);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Same funded state, two valid orderings: cancellation must never erase earned claims.
    function testFuzz_claimAndCancellationCommute(uint256 amountSeed, uint256 maskSeed) public {
        uint256[] memory amounts = new uint256[](5);
        uint256[] memory deadlines = new uint256[](5);
        uint256 total;
        uint256 earned;
        // At least one approved and one pending milestone on every run.
        uint256 approvedMask = bound(maskSeed, 1, 30);
        for (uint256 i; i < 5; ++i) {
            amounts[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 1, SUPPLY / 5);
            deadlines[i] = block.timestamp + 1;
            total += amounts[i];
            if ((approvedMask & (1 << i)) != 0) earned += amounts[i];
        }
        token.approve(address(escrow), total);
        uint256 id = escrow.openEscrow(RECIPIENT, ARBITER, amounts, deadlines);
        for (uint256 i; i < 5; ++i) {
            if ((approvedMask & (1 << i)) == 0) continue;
            vm.prank(ARBITER);
            escrow.approveMilestone(id, i);
        }
        vm.warp(block.timestamp + 2);
        uint256 snapshot = vm.snapshotState();
        _claimMask(id, approvedMask);
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);
        bytes32 firstOutcome = _stateHash(id);
        assertTrue(vm.revertToState(snapshot));
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);
        // Inspect the intermediate debt, not just an empty final escrow.
        assertEq(escrow.totalLocked(), earned);
        assertEq(token.balanceOf(address(escrow)), earned);
        _claimMask(id, approvedMask);
        assertEq(_stateHash(id), firstOutcome);
        assertEq(token.balanceOf(RECIPIENT), earned);
        assertEq(token.balanceOf(address(this)), SUPPLY - earned);
        assertEq(escrow.totalLocked(), 0);
    }

    function test_maximumDeadlineDoesNotOverflowApprovalOrClaim() public {
        vm.warp(type(uint256).max - 1);
        uint256 id = _openOne(1, type(uint256).max);
        vm.warp(type(uint256).max);
        vm.expectRevert(MilestoneEscrow.DeadlineNotPassed.selector);
        escrow.reclaimMilestone(id, 0);
        vm.prank(ARBITER);
        escrow.approveMilestone(id, 0);
        vm.prank(RECIPIENT);
        escrow.claimMilestone(id, 0);
        assertEq(token.balanceOf(RECIPIENT), 1);
        assertEq(escrow.totalLocked(), 0);
    }

    /// @dev Invalid late array entries must not corrupt previously approved liabilities or consume IDs.
    function testFuzz_invalidOpeningPreservesLiveEscrow(uint256 indexSeed, bool invalidAmount) public {
        uint256 first = _openOne(1, block.timestamp + 100);
        vm.prank(ARBITER);
        escrow.approveMilestone(first, 0);
        uint256[] memory amounts = new uint256[](5);
        uint256[] memory deadlines = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            amounts[i] = 1;
            deadlines[i] = block.timestamp + 100;
        }
        uint256 index = bound(indexSeed, 0, 4);
        token.approve(address(escrow), 5);
        bytes32 beforeState = _stateHash(first);
        if (invalidAmount) amounts[index] = 0;
        else deadlines[index] = block.timestamp;
        vm.expectRevert(
            abi.encodeWithSelector(
                invalidAmount ? MilestoneEscrow.InvalidAmount.selector : MilestoneEscrow.InvalidDeadline.selector, index
            )
        );
        escrow.openEscrow(RECIPIENT, ARBITER, amounts, deadlines);
        assertEq(_stateHash(first), beforeState);
        assertEq(token.allowance(address(this), address(escrow)), 5);
        amounts[index] = 1;
        deadlines[index] = block.timestamp + 100;
        assertEq(escrow.openEscrow(RECIPIENT, ARBITER, amounts, deadlines), 2);
        assertEq(escrow.totalLocked(), 6);
    }

    function test_erc20AllowanceCannotBypassEscrowPaymentRights() public {
        uint256 id = _openOne(SUPPLY, block.timestamp + 100);
        address[4] memory callers = [address(this), RECIPIENT, ARBITER, address(0xBAD)];
        bytes32 beforeState = _stateHash(id);
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, callers[i], 0, 1));
            vm.prank(callers[i]);
            token.transferFrom(address(escrow), callers[i], 1);
            assertEq(_stateHash(id), beforeState);
        }
        vm.prank(ARBITER);
        escrow.cancelEscrow(id);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function _openOne(uint256 amount, uint256 deadline) private returns (uint256) {
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory deadlines = new uint256[](1);
        amounts[0] = amount;
        deadlines[0] = deadline;
        token.approve(address(escrow), amount);
        return escrow.openEscrow(RECIPIENT, ARBITER, amounts, deadlines);
    }

    function _claimMask(uint256 id, uint256 mask) private {
        for (uint256 i; i < 5; ++i) {
            if ((mask & (1 << i)) == 0) continue;
            vm.prank(RECIPIENT);
            escrow.claimMilestone(id, i);
        }
    }

    function _stateHash(uint256 id) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                escrow.getEscrow(id),
                escrow.escrowCount(),
                escrow.totalLocked(),
                token.totalSupply(),
                token.balanceOf(address(this)),
                token.balanceOf(RECIPIENT),
                token.balanceOf(ARBITER),
                token.balanceOf(address(escrow))
            )
        );
    }
}
