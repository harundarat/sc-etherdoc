// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/ERC20.sol";

contract MockLinkToken is ERC20 {
    constructor() ERC20("Chainlink", "LINK") {
        _mint(msg.sender, 1_000_000 ether);
    }
}
