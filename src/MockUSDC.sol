// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Stand-in for USDC on testnets. Anyone can mint, so this must never
///         be deployed to mainnet.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "mUSDC") {}

    /// @dev Real USDC uses 6 decimals, not the ERC-20 default of 18.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Open faucet for testing. Deliberately unrestricted.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
