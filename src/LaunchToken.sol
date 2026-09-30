// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The fixed-supply Milestone launch currency.
/// @dev The deployment caller receives the entire supply; there are no privileged roles.
contract LaunchToken is ERC20 {
    constructor() ERC20("Milestone", "MILE") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
