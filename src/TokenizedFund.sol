// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title TokenizedFund
/// @notice A tokenized money market fund. Investors subscribe a stablecoin and
///         receive shares priced at the current NAV per share. Yield accrues by
///         raising NAV per share over time, so the share count held by an
///         investor never changes while its value does.
/// @dev    Testnet demonstration only. Not audited, not a real fund.
contract TokenizedFund is ERC20, AccessControl {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------

    /// @notice Permitted to set the yield rate and deposit yield. In a real fund
    ///         this is the administrator striking the daily NAV.
    bytes32 public constant NAV_UPDATER_ROLE = keccak256("NAV_UPDATER_ROLE");

    /// @notice Permitted to maintain the eligible-holder register: approving and
    ///         revoking holders, freezing accounts, and forcing transfers. This
    ///         is the transfer agent's role in a real fund.
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    // -------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------

    /// @dev Fixed-point scale for navPerShare arithmetic. 1e18 == $1.00.
    uint256 private constant NAV_PRECISION = 1e18;

    /// @dev Basis points denominator. 10_000 bps == 100%.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Accrual year length. Money market funds quote yields on an annual
    ///      basis, so elapsed seconds are measured against this.
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    /// @dev Sanity ceiling on the yield rate. A money market fund earning more
    ///      than 20% a year is a bug, not a windfall.
    uint256 private constant MAX_ANNUAL_RATE_BPS = 2_000;

    // -------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------

    /// @notice The stablecoin investors subscribe and redeem with.
    IERC20 public immutable asset;

    /// @notice Annual yield rate in basis points. 500 == 5.00% a year.
    uint256 public annualRateBps;

    /// @dev NAV per share as of `lastAccrualTime`. Reading the live value should
    ///      go through `currentNavPerShare()`, which adds yield since then.
    uint256 public navPerShareCheckpoint;

    /// @notice Timestamp the checkpoint above was last written.
    uint256 public lastAccrualTime;

    /// @notice The eligible-holder register. Shares are a security, so only
    ///         approved addresses may hold them.
    mapping(address => bool) public isWhitelisted;

    /// @notice Accounts blocked from moving shares in either direction, while
    ///         remaining on the register. Used for sanctions hits and disputes.
    mapping(address => bool) public isFrozen;

    // -------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------

    event Subscribed(
        address indexed investor,
        uint256 assetsIn,
        uint256 sharesOut,
        uint256 navPerShare
    );

    event Redeemed(
        address indexed investor,
        uint256 sharesIn,
        uint256 assetsOut,
        uint256 navPerShare
    );

    event Accrued(uint256 oldNav, uint256 newNav, uint256 elapsedSeconds);

    event RateUpdated(uint256 oldRateBps, uint256 newRateBps);

    event YieldDeposited(address indexed from, uint256 amount);

    event WhitelistUpdated(address indexed account, bool approved);

    event FrozenUpdated(address indexed account, bool frozen);

    event ForcedTransfer(address indexed from, address indexed to, uint256 value);

    // -------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------

    error ZeroAmount();
    error RateTooHigh(uint256 requested, uint256 maximum);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error NotWhitelisted(address account);
    error AccountFrozen(address account);

    // -------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------

    /// @param _asset The stablecoin used for subscription and redemption.
    /// @param _admin Address granted both admin and NAV updater roles.
    /// @param _annualRateBps Starting annual yield, in basis points.
    constructor(IERC20 _asset, address _admin, uint256 _annualRateBps)
        ERC20("Tokenized Treasury Fund", "TTF")
    {
        if (_annualRateBps > MAX_ANNUAL_RATE_BPS) {
            revert RateTooHigh(_annualRateBps, MAX_ANNUAL_RATE_BPS);
        }

        asset = _asset;
        annualRateBps = _annualRateBps;
        navPerShareCheckpoint = NAV_PRECISION; // Fund launches at exactly $1.00
        lastAccrualTime = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(NAV_UPDATER_ROLE, _admin);
        _grantRole(COMPLIANCE_ROLE, _admin);
    }

    /// @dev Match the asset's 6 decimals so subscribe/redeem needs no rescaling.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // -------------------------------------------------------------------
    // NAV accrual
    // -------------------------------------------------------------------

    /// @notice NAV per share right now, including yield earned since the last
    ///         checkpoint. This is the price subscriptions and redemptions use.
    /// @dev Simple (non-compounding) interest over elapsed time. Real money
    ///      market funds accrue daily on a simple basis, so this mirrors them
    ///      and keeps the arithmetic auditable by hand.
    function currentNavPerShare() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastAccrualTime;
        if (elapsed == 0 || annualRateBps == 0) {
            return navPerShareCheckpoint;
        }

        uint256 growth = (navPerShareCheckpoint * annualRateBps * elapsed)
            / (BPS_DENOMINATOR * SECONDS_PER_YEAR);

        return navPerShareCheckpoint + growth;
    }

    /// @notice Write the accrued NAV into storage and restart the clock.
    /// @dev Called before any action that depends on the price, and before any
    ///      rate change, so yield already earned is locked in at the old rate.
    function accrue() public {
        uint256 updated = currentNavPerShare();
        if (updated == navPerShareCheckpoint) {
            lastAccrualTime = block.timestamp;
            return;
        }

        uint256 oldNav = navPerShareCheckpoint;
        uint256 elapsed = block.timestamp - lastAccrualTime;

        navPerShareCheckpoint = updated;
        lastAccrualTime = block.timestamp;

        emit Accrued(oldNav, updated, elapsed);
    }

    // -------------------------------------------------------------------
    // Investor actions
    // -------------------------------------------------------------------

    /// @notice Deposit assets and receive shares at the current NAV.
    /// @param assetAmount Amount of the stablecoin to subscribe, in 6 decimals.
    /// @return sharesOut Number of shares issued.
    function subscribe(uint256 assetAmount) external returns (uint256 sharesOut) {
        if (assetAmount == 0) revert ZeroAmount();

        accrue();

        // shares = assets / navPerShare
        sharesOut = (assetAmount * NAV_PRECISION) / navPerShareCheckpoint;
        if (sharesOut == 0) revert ZeroAmount();

        // Pull the investor's stablecoin in, then issue their shares.
        asset.safeTransferFrom(msg.sender, address(this), assetAmount);
        _mint(msg.sender, sharesOut);

        emit Subscribed(msg.sender, assetAmount, sharesOut, navPerShareCheckpoint);
    }

    /// @notice Burn shares and receive assets back at the current NAV.
    /// @param shareAmount Number of shares to redeem, in 6 decimals.
    /// @return assetsOut Amount of stablecoin returned.
    function redeem(uint256 shareAmount) external returns (uint256 assetsOut) {
        if (shareAmount == 0) revert ZeroAmount();

        accrue();

        // assets = shares * navPerShare
        assetsOut = (shareAmount * navPerShareCheckpoint) / NAV_PRECISION;

        uint256 available = asset.balanceOf(address(this));
        if (assetsOut > available) {
            revert InsufficientLiquidity(assetsOut, available);
        }

        // Burn first, then pay out. Burning reverts if the balance is too low.
        _burn(msg.sender, shareAmount);
        asset.safeTransfer(msg.sender, assetsOut);

        emit Redeemed(msg.sender, shareAmount, assetsOut, navPerShareCheckpoint);
    }

    // -------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------

    /// @notice Change the annual yield rate going forward.
    /// @dev Accrues first, so the new rate never rewrites yield already earned.
    /// @param newRateBps New annual rate in basis points.
    function setAnnualRate(uint256 newRateBps) external onlyRole(NAV_UPDATER_ROLE) {
        if (newRateBps > MAX_ANNUAL_RATE_BPS) {
            revert RateTooHigh(newRateBps, MAX_ANNUAL_RATE_BPS);
        }

        accrue();

        uint256 oldRateBps = annualRateBps;
        annualRateBps = newRateBps;

        emit RateUpdated(oldRateBps, newRateBps);
    }

    /// @notice Pay the interest earned on the underlying holdings into the fund.
    /// @dev NAV rising is only a promise; this is what makes it payable. Without
    ///      it the fund owes redeemers more than it holds. In a real fund this is
    ///      the manager depositing T-bill coupon proceeds as they settle.
    /// @param amount Amount of the stablecoin to deposit, in 6 decimals.
    function depositYield(uint256 amount) external onlyRole(NAV_UPDATER_ROLE) {
        if (amount == 0) revert ZeroAmount();

        asset.safeTransferFrom(msg.sender, address(this), amount);

        emit YieldDeposited(msg.sender, amount);
    }

    // -------------------------------------------------------------------
    // Compliance
    // -------------------------------------------------------------------

    /// @notice Add or remove an address from the eligible-holder register.
    /// @dev Revoking does not claw back shares already held. It stops the holder
    ///      acquiring or sending more; the transfer agent uses `forceTransfer`
    ///      to actually move them out.
    function setWhitelisted(address account, bool approved)
        external
        onlyRole(COMPLIANCE_ROLE)
    {
        isWhitelisted[account] = approved;
        emit WhitelistUpdated(account, approved);
    }

    /// @notice Freeze or unfreeze an account. A frozen holder stays on the
    ///         register but cannot send, receive, or redeem.
    function setFrozen(address account, bool frozen) external onlyRole(COMPLIANCE_ROLE) {
        isFrozen[account] = frozen;
        emit FrozenUpdated(account, frozen);
    }

    /// @notice Move shares between holders without the sender's consent.
    /// @dev The transfer agent power. Real funds need this for court orders,
    ///      lost keys, and inheritance. The destination must still be eligible,
    ///      so shares can never be forced onto an unapproved address.
    function forceTransfer(address from, address to, uint256 value)
        external
        onlyRole(COMPLIANCE_ROLE)
    {
        if (!isWhitelisted[to]) revert NotWhitelisted(to);

        // Deliberately calls the parent implementation, bypassing the gate in
        // this contract's `_update`. That bypass is the whole point: the sender
        // may be frozen or already struck off the register.
        super._update(from, to, value);

        emit ForcedTransfer(from, to, value);
    }

    /// @dev Single hook every mint, burn, and transfer passes through in
    ///      OpenZeppelin v5. `from == address(0)` is a mint (subscription) and
    ///      `to == address(0)` is a burn (redemption).
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0)) {
            // Subscribing: the new holder must be eligible and not frozen.
            if (!isWhitelisted[to]) revert NotWhitelisted(to);
            if (isFrozen[to]) revert AccountFrozen(to);
        } else if (to == address(0)) {
            // Redeeming: a frozen holder cannot cash out.
            if (isFrozen[from]) revert AccountFrozen(from);
        } else {
            // Transferring: both sides must be eligible and unfrozen.
            if (!isWhitelisted[from]) revert NotWhitelisted(from);
            if (!isWhitelisted[to]) revert NotWhitelisted(to);
            if (isFrozen[from]) revert AccountFrozen(from);
            if (isFrozen[to]) revert AccountFrozen(to);
        }

        super._update(from, to, value);
    }

    // -------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------

    /// @notice Current value of an investor's holding, in asset terms.
    function balanceInAssets(address investor) external view returns (uint256) {
        return (balanceOf(investor) * currentNavPerShare()) / NAV_PRECISION;
    }

    /// @notice Total value of all shares outstanding, in asset terms.
    function totalAssetsUnderManagement() external view returns (uint256) {
        return (totalSupply() * currentNavPerShare()) / NAV_PRECISION;
    }

    /// @notice Stablecoin the fund actually holds right now.
    function assetsHeld() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice True when the fund holds enough to pay every share at today's NAV.
    /// @dev False means yield has accrued that has not yet been deposited, so
    ///      late redeemers would be unable to exit.
    function isFullyBacked() external view returns (bool) {
        return assetsHeld() >= (totalSupply() * currentNavPerShare()) / NAV_PRECISION;
    }
}
