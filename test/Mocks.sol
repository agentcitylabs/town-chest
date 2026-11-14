// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Stands in for AGENT CITY: 18 decimals, mintable.
contract MockCity is ERC20 {
    constructor() ERC20("Mock AGENT CITY", "CITY") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Burns 1% of every transfer: a deposit of it must be counted by what arrived.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Taxed", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 tax = value / 100;
            super._update(from, address(0), tax);
            value -= tax;
        }
        super._update(from, to, value);
    }
}

/// A receiver that refuses ETH: a rescue to it must fail, not vanish.
contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}
