// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    LaunchToken private token;
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private spender = address(0x5EED);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new LaunchToken();
    }

    function testMetadataAndInitialSupply() public view {
        assertEq(token.name(), "Milestone");
        assertEq(token.symbol(), "MILE");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testConstructorMintsToActualDeployer() public {
        vm.prank(alice);
        LaunchToken another = new LaunchToken();
        assertEq(another.balanceOf(alice), SUPPLY);
        assertEq(another.balanceOf(address(this)), 0);
        assertEq(another.totalSupply(), SUPPLY);
    }

    function testTransferEmitsEventAndMovesExactAmount() public {
        uint256 amount = 123 ether;
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testZeroTransferSucceedsWithoutChangingBalances() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testSelfTransferPreservesBalance() public {
        assertTrue(token.transfer(address(this), 1 ether));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferRejectsInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferRejectsZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testApproveAndTransferFromSpendAllowance() public {
        uint256 approval = 10 ether;
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, approval);
        assertTrue(token.approve(spender, approval));
        assertEq(token.allowance(address(this), spender), approval);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 4 ether));
        assertEq(token.balanceOf(alice), 4 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 4 ether);
        assertEq(token.allowance(address(this), spender), 6 ether);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, 6 ether));
        assertEq(token.balanceOf(bob), 6 ether);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testApproveCanReplaceAndRevokeAllowance() public {
        token.approve(spender, 10 ether);
        token.approve(spender, 3 ether);
        assertEq(token.allowance(address(this), spender), 3 ether);
        token.approve(spender, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testInfiniteAllowanceIsNotDecremented() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1 ether);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferFromRejectsInsufficientAllowanceWithoutChanges() public {
        token.approve(spender, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1 ether, 2 ether)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, 2 ether);
        assertEq(token.allowance(address(this), spender), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testTransferFromBalanceFailurePreservesAllowance() public {
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 10 ether);
        assertEq(token.allowance(alice, spender), 10 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferFromZeroRecipientPreservesAllowance() public {
        token.approve(spender, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 1 ether);
        assertEq(token.allowance(address(this), spender), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testApproveRejectsZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1 ether);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function testMintIsUnavailableToDeployerAndOtherAccounts() public {
        bytes memory callData = abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether);
        (bool deployerSuccess,) = address(token).call(callData);
        assertFalse(deployerSuccess);
        vm.prank(alice);
        (bool outsiderSuccess,) = address(token).call(callData);
        assertFalse(outsiderSuccess);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzzTransfersConserveSupply(uint256 firstAmount, uint256 secondAmount) public {
        firstAmount = bound(firstAmount, 0, SUPPLY);
        secondAmount = bound(secondAmount, 0, firstAmount);
        token.transfer(alice, firstAmount);
        vm.prank(alice);
        token.transfer(bob, secondAmount);

        assertEq(token.balanceOf(address(this)), SUPPLY - firstAmount);
        assertEq(token.balanceOf(alice), firstAmount - secondAmount);
        assertEq(token.balanceOf(bob), secondAmount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
