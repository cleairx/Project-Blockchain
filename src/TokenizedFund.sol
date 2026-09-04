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

    /// @notice Permitted to update NAV. In a real fund this is the administrator
    ///         striking the daily NAV.
    bytes32 public constant NAV_UPDATER_ROLE = keccak256("NAV_UPDATER_ROLE");

    // -------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------

    /// @notice The stablecoin investors subscribe and redeem with.
    IERC20 public immutable asset;

    /// @notice Value of one share, as 18-decimal fixed point. 1e18 == $1.00.
    uint256 public navPerShare;

    /// @dev Fixed-point scale for navPerShare arithmetic.
    uint256 private constant NAV_PRECISION = 1e18;

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

    event NavUpdated(uint256 oldNav, uint256 newNav);

    // -------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------

    error ZeroAmount();
    error NavCannotDecrease();
    error InsufficientLiquidity(uint256 requested, uint256 available);

    // -------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------

    /// @param _asset The stablecoin used for subscription and redemption.
    /// @param _admin Address granted both admin and NAV updater roles.
    constructor(IERC20 _asset, address _admin)
        ERC20("Tokenized Treasury Fund", "TTF")
    {
        asset = _asset;
        navPerShare = NAV_PRECISION; // Fund launches at exactly $1.00 per share

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(NAV_UPDATER_ROLE, _admin);
    }

    /// @dev Match the asset's 6 decimals so subscribe/redeem needs no rescaling.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // -------------------------------------------------------------------
    // Investor actions
    // -------------------------------------------------------------------

    /// @notice Deposit assets and receive shares at the current NAV.
    /// @param assetAmount Amount of the stablecoin to subscribe, in 6 decimals.
    /// @return sharesOut Number of shares issued.
    function subscribe(uint256 assetAmount) external returns (uint256 sharesOut) {
        if (assetAmount == 0) revert ZeroAmount();

        // shares = assets / navPerShare
        sharesOut = (assetAmount * NAV_PRECISION) / navPerShare;
        if (sharesOut == 0) revert ZeroAmount();

        // Pull the investor's stablecoin in, then issue their shares.
        asset.safeTransferFrom(msg.sender, address(this), assetAmount);
        _mint(msg.sender, sharesOut);

        emit Subscribed(msg.sender, assetAmount, sharesOut, navPerShare);
    }

    /// @notice Burn shares and receive assets back at the current NAV.
    /// @param shareAmount Number of shares to redeem, in 6 decimals.
    /// @return assetsOut Amount of stablecoin returned.
    function redeem(uint256 shareAmount) external returns (uint256 assetsOut) {
        if (shareAmount == 0) revert ZeroAmount();

        // assets = shares * navPerShare
        assetsOut = (shareAmount * navPerShare) / NAV_PRECISION;

        uint256 available = asset.balanceOf(address(this));
        if (assetsOut > available) {
            revert InsufficientLiquidity(assetsOut, available);
        }

        // Burn first, then pay out. Burning reverts if the balance is too low.
        _burn(msg.sender, shareAmount);
        asset.safeTransfer(msg.sender, assetsOut);

        emit Redeemed(msg.sender, shareAmount, assetsOut, navPerShare);
    }

    // -------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------

    /// @notice Set a new NAV per share, reflecting yield earned on the holdings.
    /// @dev Restricted to NAV_UPDATER_ROLE. A money market fund holding T-bills
    ///      should not mark down, so decreases are rejected as a safety check.
    /// @param newNav New value of one share, 18-decimal fixed point.
    function updateNav(uint256 newNav) external onlyRole(NAV_UPDATER_ROLE) {
        if (newNav < navPerShare) revert NavCannotDecrease();

        uint256 oldNav = navPerShare;
        navPerShare = newNav;

        emit NavUpdated(oldNav, newNav);
    }

    // -------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------

    /// @notice Current value of an investor's holding, in asset terms.
    function balanceInAssets(address investor) external view returns (uint256) {
        return (balanceOf(investor) * navPerShare) / NAV_PRECISION;
    }

    /// @notice Total value of all shares outstanding, in asset terms.
    function totalAssetsUnderManagement() external view returns (uint256) {
        return (totalSupply() * navPerShare) / NAV_PRECISION;
    }
}
