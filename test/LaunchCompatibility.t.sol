// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";

/// @dev Models constructor execution by a factory without environment variables or deployment keys.
contract LocalFactory {
    function deploy() external returns (LaunchToken token, MilestoneEscrow escrow) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        escrow = new MilestoneEscrow{salt: bytes32(uint256(2))}(address(token));
    }
}

contract LaunchCompatibilityTest is Test {
    function testFactoryDeploymentPreservesSupplyAndConfiguresEscrowWithoutInitialization() public {
        LocalFactory factory = new LocalFactory();
        (LaunchToken token, MilestoneEscrow escrow) = factory.deploy();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(address(escrow.token()), address(token));
        assertEq(escrow.escrowCount(), 0);
        assertEq(escrow.totalLocked(), 0);
        _assertRuntime(address(token).code);
        _assertRuntime(address(escrow).code);
    }

    function testEscrowAndTokenRejectNativeCurrency() public {
        LaunchToken token = new LaunchToken();
        MilestoneEscrow escrow = new MilestoneEscrow(address(token));
        vm.deal(address(this), 2 ether);
        (bool tokenAccepted,) = address(token).call{value: 1 ether}("");
        (bool escrowAccepted,) = address(escrow).call{value: 1 ether}("");
        assertFalse(tokenAccepted);
        assertFalse(escrowAccepted);
    }

    function _assertRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }
}
