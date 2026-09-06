// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {TokenizedFund} from "../src/TokenizedFund.sol";

/// @title Deploy
/// @notice Deploys the mock stablecoin and the fund to a testnet, then puts the
///         deployer on the eligible-holder register so the fund is usable
///         immediately. Testnet only — MockUSDC has an open faucet.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url base_sepolia --broadcast --verify
contract Deploy is Script {
    /// @dev 500 bps == 5.00% a year, roughly a short-dated T-bill yield.
    uint256 internal constant ANNUAL_RATE_BPS = 500;

    /// @dev Faucet balance handed to the deployer for demonstrating subscribe.
    uint256 internal constant SEED_USDC = 10_000e6;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockUSDC usdc = new MockUSDC();
        TokenizedFund fund = new TokenizedFund(usdc, deployer, ANNUAL_RATE_BPS);

        // The deployer is the transfer agent, so approve them as a holder and
        // give them test dollars to subscribe with.
        fund.setWhitelisted(deployer, true);
        usdc.mint(deployer, SEED_USDC);

        vm.stopBroadcast();

        console.log("Deployer:      ", deployer);
        console.log("MockUSDC:      ", address(usdc));
        console.log("TokenizedFund: ", address(fund));
        console.log("Annual rate:    500 bps (5.00%)");
    }
}
