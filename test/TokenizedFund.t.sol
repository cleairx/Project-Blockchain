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
    address internal investor2 = address(0xCA1E);
    address internal outsider = address(0xDEAD);

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

        // Shares are a security: holders must be on the register before they
        // can receive any. `outsider` is deliberately left off it.
        vm.startPrank(admin);
        fund.setWhitelisted(investor, true);
        fund.setWhitelisted(investor2, true);
        vm.stopPrank();
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

    // -------------------------------------------------------------------
    // The eligible-holder register
    // -------------------------------------------------------------------

    function test_UnapprovedAddressCannotSubscribe() public {
        usdc.mint(outsider, DEPOSIT);

        vm.startPrank(outsider);
        usdc.approve(address(fund), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedFund.NotWhitelisted.selector, outsider)
        );
        fund.subscribe(DEPOSIT);
        vm.stopPrank();
    }

    function test_TransferBetweenApprovedHoldersWorks() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        vm.prank(investor);
        fund.transfer(investor2, 400e6);

        assertEq(fund.balanceOf(investor), 600e6);
        assertEq(fund.balanceOf(investor2), 400e6);
    }

    function test_TransferToUnapprovedAddressFails() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedFund.NotWhitelisted.selector, outsider)
        );
        fund.transfer(outsider, 1e6);
    }

    function test_RevokingApprovalBlocksFurtherSending() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        // Struck off the register — the shares stay put, but cannot move.
        vm.prank(admin);
        fund.setWhitelisted(investor, false);

        assertEq(fund.balanceOf(investor), DEPOSIT);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedFund.NotWhitelisted.selector, investor)
        );
        fund.transfer(investor2, 1e6);
    }

    // -------------------------------------------------------------------
    // Freezing
    // -------------------------------------------------------------------

    function test_FrozenHolderCannotSend() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        vm.prank(admin);
        fund.setFrozen(investor, true);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedFund.AccountFrozen.selector, investor)
        );
        fund.transfer(investor2, 1e6);
    }

    function test_FrozenHolderCannotReceive() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        vm.prank(admin);
        fund.setFrozen(investor2, true);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedFund.AccountFrozen.selector, investor2)
        );
        fund.transfer(investor2, 1e6);
    }

    function test_FrozenHolderCannotRedeem() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        vm.prank(admin);
        fund.setFrozen(investor, true);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedFund.AccountFrozen.selector, investor)
        );
        fund.redeem(100e6);
    }

    function test_UnfreezingRestoresNormalTransfers() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        vm.startPrank(admin);
        fund.setFrozen(investor, true);
        fund.setFrozen(investor, false);
        vm.stopPrank();

        vm.prank(investor);
        fund.transfer(investor2, 1e6);

        assertEq(fund.balanceOf(investor2), 1e6);
    }

    // -------------------------------------------------------------------
    // Transfer agent powers
    // -------------------------------------------------------------------

    function test_ForceTransferMovesSharesFromAFrozenHolder() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        vm.startPrank(admin);
        fund.setFrozen(investor, true);
        // Court order, lost keys, inheritance: the agent moves them anyway.
        fund.forceTransfer(investor, investor2, DEPOSIT);
        vm.stopPrank();

        assertEq(fund.balanceOf(investor), 0);
        assertEq(fund.balanceOf(investor2), DEPOSIT);
    }

    function test_ForceTransferStillRequiresAnApprovedDestination() public {
        vm.prank(investor);
        fund.subscribe(DEPOSIT);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedFund.NotWhitelisted.selector, outsider)
        );
        fund.forceTransfer(investor, outsider, 1e6);
    }

    function test_OnlyComplianceRoleCanManageTheRegister() public {
        vm.prank(investor);
        vm.expectRevert();
        fund.setWhitelisted(outsider, true);

        vm.prank(investor);
        vm.expectRevert();
        fund.setFrozen(investor2, true);

        vm.prank(investor);
        vm.expectRevert();
        fund.forceTransfer(investor, investor2, 1e6);
    }
}
