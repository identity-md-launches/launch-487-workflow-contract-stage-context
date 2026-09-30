// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";

/// @dev The handler never transfers unsolicited tokens and bounds the system to forty milestones.
contract EscrowHandler is Test {
    uint256 public constant MAX_ESCROWS = 8;
    address private constant OUTSIDER = address(0xBAD);

    LaunchToken public immutable token;
    MilestoneEscrow public immutable escrow;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE), address(0xDA7A)];
    mapping(address actor => uint256 amount) public expectedBalance;
    mapping(uint256 escrowId => bytes32 terms) public originalTerms;
    uint256[5] public successfulActions;
    uint256 public unexpectedResults;

    constructor(LaunchToken token_, MilestoneEscrow escrow_) {
        token = token_;
        escrow = escrow_;
        for (uint256 i; i < actors.length; ++i) {
            expectedBalance[actors[i]] = token_.totalSupply() / actors.length;
            vm.prank(actors[i]);
            token_.approve(address(escrow_), type(uint256).max);
        }
    }

    function open(uint256 partySeed, uint256 countSeed, uint256 amountSeed, uint256 deadlineSeed) external {
        if (escrow.escrowCount() == MAX_ESCROWS) return;
        address funder = actors[partySeed % actors.length];
        address recipient = actors[(partySeed >> 8) % actors.length];
        address arbiter = actors[(partySeed >> 16) % actors.length];
        uint256 count = 1 + countSeed % 5;
        uint256[] memory amounts = new uint256[](count);
        uint256[] memory deadlines = new uint256[](count);
        uint256 total;
        for (uint256 i; i < count; ++i) {
            amounts[i] = 1 + uint256(keccak256(abi.encode(amountSeed, i))) % (1_000 ether);
            deadlines[i] = block.timestamp + 1 + uint256(keccak256(abi.encode(deadlineSeed, i))) % 30 days;
            total += amounts[i];
        }

        vm.prank(funder);
        try escrow.openEscrow(recipient, arbiter, amounts, deadlines) returns (uint256 id) {
            expectedBalance[funder] -= total;
            originalTerms[id] = keccak256(abi.encode(funder, recipient, arbiter, amounts, deadlines));
            ++successfulActions[0];
        } catch {
            // Every generated opening is valid and adequately funded; a revert is a regression.
            ++unexpectedResults;
        }
    }

    function approve(uint256 escrowSeed, uint256 milestoneSeed, bool authorized) external {
        (uint256 id, uint256 index, bool found) = _findEligible(escrowSeed, milestoneSeed, 0);
        if (!found) return;
        MilestoneEscrow.Escrow memory item = escrow.getEscrow(id);
        if (_call(item.arbiter, authorized, abi.encodeCall(escrow.approveMilestone, (id, index)))) {
            ++successfulActions[1];
        }
    }

    function claim(uint256 escrowSeed, uint256 milestoneSeed, bool authorized) external {
        (uint256 id, uint256 index, bool found) = _findEligible(escrowSeed, milestoneSeed, 1);
        if (!found) return;
        MilestoneEscrow.Escrow memory item = escrow.getEscrow(id);
        if (_call(item.recipient, authorized, abi.encodeCall(escrow.claimMilestone, (id, index)))) {
            expectedBalance[item.recipient] += item.milestones[index].amount;
            ++successfulActions[2];
        }
    }

    function reclaim(uint256 escrowSeed, uint256 milestoneSeed, bool authorized) external {
        (uint256 id, uint256 index, bool found) = _findEligible(escrowSeed, milestoneSeed, 2);
        if (!found) return;
        MilestoneEscrow.Escrow memory item = escrow.getEscrow(id);
        if (_call(item.funder, authorized, abi.encodeCall(escrow.reclaimMilestone, (id, index)))) {
            expectedBalance[item.funder] += item.milestones[index].amount;
            ++successfulActions[3];
        }
    }

    function cancel(uint256 escrowSeed, bool authorized) external {
        uint256 count = escrow.escrowCount();
        if (count == 0) return;
        for (uint256 i; i < count; ++i) {
            uint256 id = 1 + (escrowSeed % count + i) % count;
            MilestoneEscrow.Escrow memory item = escrow.getEscrow(id);
            if (item.cancelled) continue;
            uint256 refund;
            for (uint256 j; j < item.milestones.length; ++j) {
                if (item.milestones[j].status == MilestoneEscrow.MilestoneStatus.Pending) {
                    refund += item.milestones[j].amount;
                }
            }
            if (_call(item.arbiter, authorized, abi.encodeCall(escrow.cancelEscrow, (id)))) {
                expectedBalance[item.funder] += refund;
                ++successfulActions[4];
            }
            return;
        }
    }

    function advanceTime(uint256 elapsed) external {
        vm.warp(block.timestamp + _bound(elapsed, 0, 30 days));
    }

    /// @dev action: 0 = timely approval, 1 = approved claim, 2 = expired pending refund.
    function _findEligible(uint256 escrowSeed, uint256 milestoneSeed, uint256 action)
        private
        view
        returns (uint256 id, uint256 index, bool found)
    {
        uint256 count = escrow.escrowCount();
        if (count == 0) return (0, 0, false);
        for (uint256 i; i < count; ++i) {
            id = 1 + (escrowSeed % count + i) % count;
            MilestoneEscrow.Escrow memory item = escrow.getEscrow(id);
            uint256 length = item.milestones.length;
            for (uint256 j; j < length; ++j) {
                index = (milestoneSeed % length + j) % length;
                MilestoneEscrow.Milestone memory milestone = item.milestones[index];
                if (
                    action == 0 && !item.cancelled && milestone.status == MilestoneEscrow.MilestoneStatus.Pending
                        && block.timestamp <= milestone.deadline
                ) return (id, index, true);
                if (action == 1 && milestone.status == MilestoneEscrow.MilestoneStatus.Approved) {
                    return (id, index, true);
                }
                if (
                    action == 2 && milestone.status == MilestoneEscrow.MilestoneStatus.Pending
                        && block.timestamp > milestone.deadline
                ) return (id, index, true);
            }
        }
        return (0, 0, false);
    }

    function _call(address role, bool authorized, bytes memory data) private returns (bool success) {
        vm.prank(authorized ? role : OUTSIDER);
        (success,) = address(escrow).call(data);
        if (success != authorized) ++unexpectedResults;
    }
}

contract EscrowInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    LaunchToken private token;
    MilestoneEscrow private escrow;
    EscrowHandler private handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new LaunchToken();
        escrow = new MilestoneEscrow(address(token));
        handler = new EscrowHandler(token, escrow);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), SUPPLY / 4);
        }
        handler.open(0x020100, 2, 100, 200);
        handler.open(0x000302, 4, 300, 400);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = EscrowHandler.open.selector;
        selectors[1] = EscrowHandler.approve.selector;
        selectors[2] = EscrowHandler.claim.selector;
        selectors[3] = EscrowHandler.reclaim.selector;
        selectors[4] = EscrowHandler.cancel.selector;
        selectors[5] = EscrowHandler.advanceTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantLiabilitiesMatchCustodyAndOriginalTerms() public view {
        uint256 outstanding;
        uint256 count = escrow.escrowCount();
        assertLe(count, handler.MAX_ESCROWS());
        for (uint256 id = 1; id <= count; ++id) {
            MilestoneEscrow.Escrow memory item = escrow.getEscrow(id);
            uint256 total;
            uint256 remaining;
            uint256 length = item.milestones.length;
            uint256[] memory amounts = new uint256[](length);
            uint256[] memory deadlines = new uint256[](length);
            for (uint256 j; j < length; ++j) {
                MilestoneEscrow.Milestone memory milestone = item.milestones[j];
                amounts[j] = milestone.amount;
                deadlines[j] = milestone.deadline;
                total += milestone.amount;
                if (
                    milestone.status == MilestoneEscrow.MilestoneStatus.Pending
                        || milestone.status == MilestoneEscrow.MilestoneStatus.Approved
                ) remaining += milestone.amount;
                if (item.cancelled) assertTrue(milestone.status != MilestoneEscrow.MilestoneStatus.Pending);
            }
            assertEq(item.totalAmount, total);
            assertEq(item.remainingAmount, remaining);
            assertEq(
                keccak256(abi.encode(item.funder, item.recipient, item.arbiter, amounts, deadlines)),
                handler.originalTerms(id)
            );
            outstanding += remaining;
        }
        assertEq(escrow.totalLocked(), outstanding);
        assertEq(token.balanceOf(address(escrow)), outstanding);
    }

    function invariantSupplyAndParticipantBalancesAreConserved() public view {
        uint256 balances = token.balanceOf(address(escrow));
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor));
            balances += balance;
        }
        assertEq(balances, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(handler.unexpectedResults(), 0, "eligible role calls must succeed; outsiders must fail");
    }

    /// @dev Ensures handler eligibility filtering reaches real transitions, including denied calls.
    function testHandlerExercisesEverySuccessfulOperation() public {
        handler.approve(0, 0, false);
        handler.approve(0, 0, true);
        handler.claim(0, 0, false);
        handler.claim(0, 0, true);
        handler.advanceTime(30 days);
        handler.advanceTime(1);
        handler.reclaim(0, 0, false);
        handler.reclaim(0, 0, true);
        handler.cancel(0, false);
        handler.cancel(0, true);
        for (uint256 i; i < 5; ++i) {
            assertGt(handler.successfulActions(i), 0);
        }
        invariantLiabilitiesMatchCustodyAndOriginalTerms();
        invariantSupplyAndParticipantBalancesAreConserved();
    }
}
