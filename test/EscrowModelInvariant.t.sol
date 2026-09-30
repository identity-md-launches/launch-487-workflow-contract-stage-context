// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MilestoneEscrow} from "src/MilestoneEscrow.sol";

/// @dev Rights are recorded from test inputs and successful actions, never from contract getters.
/// Unlike an eligibility-filtered handler, this also attempts expired, repeated and unauthorized calls.
contract EscrowModelHandler is Test {
    uint256 public constant SUPPLY = 1e27;
    uint256 public constant MAX_ESCROWS = 12;
    address[4] public actors = [address(0x1101), address(0x1102), address(0x1103), address(0x1104)];
    LaunchToken public immutable token;
    MilestoneEscrow public immutable escrow;

    struct Agreement {
        address funder;
        address recipient;
        address arbiter;
        uint256[] amounts;
        uint256[] deadlines;
        uint256 approved;
        uint256 claimed;
        uint256 refunded;
        bool cancelled;
    }

    mapping(uint256 => Agreement) private agreements;
    mapping(address => uint256) public wallet;
    uint256 public count;
    uint256 public deposited;
    uint256 public paid;
    uint256 public donations;
    uint256 public rejectedOpens;
    uint256[4] public successes;
    uint256[4] public rejections;

    constructor(LaunchToken token_, MilestoneEscrow escrow_) {
        token = token_;
        escrow = escrow_;
        for (uint256 i; i < actors.length; ++i) {
            wallet[actors[i]] = SUPPLY / actors.length;
        }
    }

    /// @dev Exact, infinite and one-unit-short approvals are all exercised. Roles may coincide.
    function open(uint256 parties, uint256 size, uint256 amountSeed, uint256 duration, uint256 allowanceMode) public {
        if (count == MAX_ESCROWS) return;
        Agreement memory next;
        next.funder = actors[parties % 4];
        next.recipient = actors[(parties >> 8) % 4];
        next.arbiter = actors[(parties >> 16) % 4];
        uint256 length = bound(size, 1, 5);
        uint256 ceiling = wallet[next.funder] / length;
        if (ceiling == 0) ceiling = 1;
        next.amounts = new uint256[](length);
        next.deadlines = new uint256[](length);
        uint256 total;
        for (uint256 i; i < length; ++i) {
            next.amounts[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 1, ceiling);
            next.deadlines[i] = block.timestamp + 1 + ((duration >> (i * 16)) % 7 days);
            total += next.amounts[i];
        }
        uint256 mode = allowanceMode % 3;
        uint256 allowance = mode == 0 ? total : mode == 1 ? type(uint256).max : total - 1;
        vm.prank(next.funder);
        assertTrue(token.approve(address(escrow), allowance));
        bool shouldSucceed = mode != 2 && total <= wallet[next.funder];
        vm.prank(next.funder);
        (bool ok, bytes memory result) = address(escrow)
            .call(abi.encodeCall(escrow.openEscrow, (next.recipient, next.arbiter, next.amounts, next.deadlines)));
        assertEq(ok, shouldSucceed, "opening must require the caller's full balance and allowance");
        if (ok) {
            ++count;
            assertEq(abi.decode(result, (uint256)), count, "failed opens must not consume IDs");
            agreements[count] = next;
            wallet[next.funder] -= total;
            deposited += total;
            if (mode == 0) allowance = 0;
        } else {
            ++rejectedOpens;
            assertGt(result.length, 0, "failed opening must revert");
        }
        assertEq(token.allowance(next.funder, address(escrow)), allowance, "allowance must roll back on failure");
    }

    /// @dev Most calls use the named role, with some outsiders, unknown IDs and invalid indices.
    /// No filtering by on-chain milestone status: settled milestones remain targets forever.
    function act(uint256 actionSeed, uint256 idSeed, uint256 indexSeed, uint256 callerSeed) public {
        uint256 action = actionSeed % 4;
        uint256 id = 1 + idSeed % count;
        if (idSeed % 16 == 15) id = count + 1;
        else if (idSeed % 16 == 14) id = 0;
        Agreement storage item = agreements[id];
        uint256 length = item.amounts.length;
        uint256 index = length == 0 ? 0 : indexSeed % length;
        if (indexSeed % 8 == 7) index = length;
        address caller = action == 1 ? item.recipient : action == 2 ? item.funder : item.arbiter;
        if (caller == address(0) || callerSeed % 4 == 0) caller = actors[(callerSeed >> 8) % 4];
        _act(action, id, index, caller);
    }

    function donate(uint256 actorSeed, uint256 amountSeed) public {
        address donor = actors[actorSeed % 4];
        uint256 amount = bound(amountSeed, 0, wallet[donor]);
        vm.prank(donor);
        assertTrue(token.transfer(address(escrow), amount));
        wallet[donor] -= amount;
        donations += amount;
    }

    /// @dev Visit exact deadlines and the following second, without ever moving time backwards.
    function advanceTime(uint256 elapsed, uint256 idSeed, uint256 indexSeed, bool boundary) public {
        uint256 next = block.timestamp + bound(elapsed, 0, 2 days);
        if (boundary) {
            Agreement storage item = agreements[1 + idSeed % count];
            next = item.deadlines[indexSeed % item.deadlines.length] + elapsed % 2;
            if (next < block.timestamp) next = block.timestamp;
        }
        vm.warp(next);
    }

    function _act(uint256 action, uint256 id, uint256 index, address caller) private {
        Agreement storage item = agreements[id];
        bool exists = id > 0 && id <= count;
        bool validIndex = index < item.amounts.length;
        uint256 bit = validIndex ? 1 << index : 0;
        bool pending = validIndex && ((item.approved | item.claimed | item.refunded) & bit) == 0;
        bool shouldSucceed;
        bytes memory data;
        if (action == 0) {
            shouldSucceed = exists && caller == item.arbiter && !item.cancelled && pending
                && block.timestamp <= item.deadlines[index];
            data = abi.encodeCall(escrow.approveMilestone, (id, index));
        } else if (action == 1) {
            shouldSucceed = exists && caller == item.recipient && validIndex && (item.approved & bit) != 0
                && (item.claimed & bit) == 0;
            data = abi.encodeCall(escrow.claimMilestone, (id, index));
        } else if (action == 2) {
            shouldSucceed = exists && caller == item.funder && pending && block.timestamp > item.deadlines[index];
            data = abi.encodeCall(escrow.reclaimMilestone, (id, index));
        } else {
            shouldSucceed = exists && caller == item.arbiter && !item.cancelled;
            data = abi.encodeCall(escrow.cancelEscrow, (id));
        }
        vm.prank(caller);
        (bool ok, bytes memory result) = address(escrow).call(data);
        assertEq(ok, shouldSucceed, "action result must match independently recorded rights");
        if (!ok) {
            ++rejections[action];
            assertGt(result.length, 0, "invalid action must revert");
            return;
        }
        ++successes[action];
        if (action == 0) {
            item.approved |= bit;
        } else if (action == 1) {
            item.claimed |= bit;
            _payout(item.recipient, item.amounts[index]);
        } else if (action == 2) {
            item.refunded |= bit;
            _payout(item.funder, item.amounts[index]);
        } else {
            item.cancelled = true;
            // Cancellation releases only rights that were never approved or already settled.
            uint256 mask = ((1 << item.amounts.length) - 1) & ~(item.approved | item.claimed | item.refunded);
            for (uint256 i; i < item.amounts.length; ++i) {
                if ((mask & (1 << i)) != 0) _payout(item.funder, item.amounts[i]);
            }
            item.refunded |= mask;
        }
    }

    function _payout(address beneficiary, uint256 amount) private {
        wallet[beneficiary] += amount;
        paid += amount;
    }

    function assertModel() public view {
        assertEq(escrow.escrowCount(), count);
        assertEq(escrow.totalLocked(), deposited - paid, "liabilities must equal net funded principal");
        uint256 custody = token.balanceOf(address(escrow));
        assertEq(custody, deposited - paid + donations, "donations must not create payment rights");
        uint256 allBalances = custody;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), wallet[actors[i]], "only the named beneficiary receives payment");
            allBalances += wallet[actors[i]];
        }
        assertEq(allBalances, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        for (uint256 id = 1; id <= count; ++id) {
            Agreement storage model = agreements[id];
            MilestoneEscrow.Escrow memory actual = escrow.getEscrow(id);
            assertEq(actual.funder, model.funder);
            assertEq(actual.recipient, model.recipient);
            assertEq(actual.arbiter, model.arbiter);
            assertEq(actual.cancelled, model.cancelled);
            assertEq(actual.milestones.length, model.amounts.length);
            uint256 total;
            uint256 remaining;
            for (uint256 i; i < model.amounts.length; ++i) {
                uint256 bit = 1 << i;
                uint256 expectedStatus = (model.claimed & bit) != 0
                    ? 2
                    : (model.refunded & bit) != 0 ? 3 : (model.approved & bit) != 0 ? 1 : 0;
                assertEq(uint256(actual.milestones[i].status), expectedStatus, "rights cannot disappear or reopen");
                assertEq(actual.milestones[i].amount, model.amounts[i]);
                assertEq(actual.milestones[i].deadline, model.deadlines[i]);
                total += model.amounts[i];
                if (((model.claimed | model.refunded) & bit) == 0) remaining += model.amounts[i];
            }
            assertEq(actual.totalAmount, total);
            assertEq(actual.remainingAmount, remaining);
        }
    }

    /// @dev End-of-sequence liveness: an absent arbiter cannot strand pending funds, and cancellation
    /// or elapsed time cannot erase approvals. This entry point is excluded from random targeting.
    function settleAll() external {
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        for (uint256 id = 1; id <= count; ++id) {
            Agreement storage item = agreements[id];
            for (uint256 i; i < item.amounts.length; ++i) {
                uint256 bit = 1 << i;
                if (((item.claimed | item.refunded) & bit) != 0) continue;
                bool approved = (item.approved & bit) != 0;
                _act(approved ? 1 : 2, id, i, approved ? item.recipient : item.funder);
            }
        }
        assertModel();
        assertEq(escrow.totalLocked(), 0, "every remaining liability must be payable");
        assertEq(token.balanceOf(address(escrow)), donations);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract EscrowModelInvariantTest is Test {
    EscrowModelHandler private handler;

    function setUp() public {
        vm.warp(1_900_000_000);
        LaunchToken token = new LaunchToken();
        MilestoneEscrow escrow = new MilestoneEscrow(address(token));
        handler = new EscrowModelHandler(token, escrow);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), 1e27 / 4);
        }
        handler.open(0x020100, 5, 11, 6 days, 0);
        handler.open(0x000302, 5, 22, 6 days, 1);
        handler.open(0x010101, 3, 33, 6 days, 0);
        handler.act(0, 0, 0, 1);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.act.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.advanceTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_rightsBalancesAndTermsMatchHistory() public view {
        handler.assertModel();
    }

    function afterInvariant() public {
        handler.settleAll();
    }

    function test_handlerReachesPaymentsReplaysFailuresDonationsAndDrain() public {
        handler.act(0, 0, 0, 1); // Repeat approval.
        handler.act(1, 0, 0, 0); // Funder is not recipient.
        handler.act(1, 0, 0, 1);
        handler.act(1, 0, 0, 1); // Repeat claim.
        handler.act(2, 0, 1, 1); // Too early to reclaim.
        handler.act(3, 1, 0, 0x0100); // Wrong arbiter.
        handler.act(3, 1, 0, 1);
        handler.act(3, 1, 0, 1); // Repeat cancellation.
        handler.open(0, 1, 1, 100, 2); // Short allowance.
        handler.donate(2, 1);
        handler.advanceTime(1, 0, 1, true); // One second after milestone 1 deadline.
        handler.act(2, 0, 1, 1);
        handler.assertModel();
        for (uint256 i; i < 4; ++i) {
            assertGt(handler.successes(i), 0, "each payment/state operation must be reachable");
            assertGt(handler.rejections(i), 0, "each operation must exercise a failure path");
        }
        assertGt(handler.rejectedOpens(), 0);
        assertEq(handler.donations(), 1);
        handler.settleAll();
    }
}
