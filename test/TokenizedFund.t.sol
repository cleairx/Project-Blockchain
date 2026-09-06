// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {TokenizedFund} from "../src/TokenizedFund.sol";

/// @title TokenizedFund NAV accrual tests
/// @notice Covers the share price rising with elapsed time, and the funding gap
///         that opens up when yield accrues but is never paid in.
contract TokenizedFundTest is Test {
    MockUSDC internal usdc;
    TokenizedFund internal fund;

    address internal admin = address(0xA11CE);
    address internal investor = address(0xB0B);

    uint256 internal constant ONE_DOLLAR = 1e18; // NAV fixed-point scale
    uint256 internal constant ONE_YEAR = 365 days;
    uint256 internal constant RATE_5_PCT = 500; // basis points

    uint256 internal constant DEPOSIT = 1_000e6; // 1,000 USDC, 6 decimals

    function setUp() public {
        usdc = new MockUSDC();
        fund = new TokenizedFund(usdc, admin, RATE_5_PCT);

        // Give the investor money and let the fund move it.
        usdc.mint(investor, DEPOSIT);
        vm.prank(investor);
        usdc.approve(address(fund), type(uint256).max);

        // The admin needs a float to pay yield in from later.
        usdc.mint(admin, DEPOSIT);
        vm.prank(admin);
        usdc.approve(address(fund), type(uint256).max);
    }

    // -------------------------------------------------------------------
    // Starting state
    // -------------------------------------------------------------------

    function test_FundLaunchesAtOneDollar() public view {
        assertEq(fund.currentNavPerShare(), ONE_DOLLAR);
    }

    function test_SubscribeIssuesSharesAtParOnDayOne() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        // At $1.00 a share, 1,000 USDC buys 1,000 shares.
        assertEq(fund.balanceOf(investor), DEPOSIT);
        assertEq(fund.totalAssetsUnderManagement(), DEPOSIT);
    }

    // -------------------------------------------------------------------
    // Accrual over time
    // -------------------------------------------------------------------

    function test_NavRisesByTheAnnualRateOverOneYear() public {
        vm.warp(block.timestamp + ONE_YEAR);

        // 5% on $1.00 is $1.05.
        assertEq(fund.currentNavPerShare(), 1.05e18);
    }

    function test_NavRisesByHalfTheRateOverHalfAYear() public {
        vm.warp(block.timestamp + ONE_YEAR / 2);

        // Simple interest, so half the time is half the yield: $1.025.
        assertEq(fund.currentNavPerShare(), 1.025e18);
    }

    function test_NavDoesNotMoveWhenNoTimePasses() public view {
        assertEq(fund.currentNavPerShare(), ONE_DOLLAR);
    }

    function test_InvestorHoldingGrowsWhileShareCountStaysFixed() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        uint256 sharesBefore = fund.balanceOf(investor);

        vm.warp(block.timestamp + ONE_YEAR);

        // The share count never changes. Only what each share is worth.
        assertEq(fund.balanceOf(investor), sharesBefore);
        assertEq(fund.balanceInAssets(investor), 1_050e6);
    }

    // -------------------------------------------------------------------
    // Rate changes
    // -------------------------------------------------------------------

    function test_RateChangeLocksInYieldAlreadyEarned() public {
        vm.warp(block.timestamp + ONE_YEAR);

        // Drop the rate to zero after a year of 5%.
        vm.prank(admin);
        fund.setAnnualRate(0);

        // The 5% already earned stays; nothing accrues from here.
        assertEq(fund.currentNavPerShare(), 1.05e18);

        vm.warp(block.timestamp + ONE_YEAR);
        assertEq(fund.currentNavPerShare(), 1.05e18);
    }

    function test_OnlyNavUpdaterCanChangeTheRate() public {
        vm.prank(investor);
        vm.expectRevert();
        fund.setAnnualRate(100);
    }

    function test_RateAboveCeilingIsRejected() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedFund.RateTooHigh.selector, 2_001, 2_000)
        );
        fund.setAnnualRate(2_001);
    }

    // -------------------------------------------------------------------
    // The funding gap
    // -------------------------------------------------------------------

    function test_AccruedYieldIsNotBackedUntilItIsPaidIn() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        assertTrue(fund.isFullyBacked());

        vm.warp(block.timestamp + ONE_YEAR);

        // NAV says the fund owes 1,050 USDC but it only holds 1,000.
        assertEq(fund.totalAssetsUnderManagement(), 1_050e6);
        assertEq(fund.assetsHeld(), 1_000e6);
        assertFalse(fund.isFullyBacked());
    }

    function test_RedeemFailsWhenYieldWasNeverDeposited() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        vm.warp(block.timestamp + ONE_YEAR);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenizedFund.InsufficientLiquidity.selector, 1_050e6, 1_000e6
            )
        );
        fund.redeem(DEPOSIT);
    }

    function test_DepositingYieldMakesTheInvestorWhole() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        vm.warp(block.timestamp + ONE_YEAR);

        // The manager pays the T-bill interest into the fund.
        vm.prank(admin);
        fund.depositYield(50e6);

        assertTrue(fund.isFullyBacked());

        vm.prank(investor);
        uint256 assetsOut = fund.redeem(DEPOSIT);

        assertEq(assetsOut, 1_050e6);
        assertEq(usdc.balanceOf(investor), 1_050e6);
        assertEq(fund.balanceOf(investor), 0);
    }

    // -------------------------------------------------------------------
    // Subscribing after the price has moved
    // -------------------------------------------------------------------

    function test_LaterInvestorPaysTheHigherPrice() public {
        vm.warp(block.timestamp + ONE_YEAR);

        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        // At $1.05 a share, 1,000 USDC buys ~952.38 shares, not 1,000.
        assertEq(fund.balanceOf(investor), 952_380952);
    }
}
