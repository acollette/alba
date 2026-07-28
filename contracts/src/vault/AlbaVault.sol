// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISleeve} from "./interfaces/ISleeve.sol";

/// @title AlbaVault — curated fixed-income ERC-4626 vault (USDC)
/// @notice One vault, multiple strategy "sleeves" under curator caps
/// (MetaMorpho's governance pattern applied to fixed income). NAV is
/// `idle USDC + Σ sleeve.totalAssets()`; withdrawal limits reflect only what is
/// instantly liquid (idle + sleeve.liquidAssets()) — honesty, not magic.
///
/// Roles: DEFAULT_ADMIN (multisig + timelock) grants roles and unpauses;
/// CURATOR manages the sleeve registry, caps and fees; ALLOCATOR (bots) moves
/// funds vault<->sleeves within caps; GUARDIAN pauses.
///
/// Trust model: sleeves are trusted code (see {ISleeve}); the underlying asset
/// is USDC (no transfer hooks), so no reentrancy guard is used.
contract AlbaVault is ERC4626, AccessControl, Pausable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ roles
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // -------------------------------------------------------------- constants
    uint256 internal constant BPS = 10_000;
    /// @notice Hard cap on the management fee: 5% / year.
    uint256 public constant MAX_FEE_BPS = 500;
    /// @notice Registry bound — keeps totalAssets() iteration cheap.
    uint256 public constant MAX_SLEEVES = 8;

    // ---------------------------------------------------------------- storage
    struct SleeveConfig {
        bool active;
        uint96 cap; // max sleeve.totalAssets() after an allocation, asset units
    }

    /// @notice Active sleeve addresses (iteration order = withdrawal-pull order).
    address[] public sleeves;
    /// @notice Per-sleeve configuration.
    mapping(address sleeve => SleeveConfig) public sleeveConfig;

    /// @notice Management fee in bps per year, accrued as share dilution.
    uint16 public feeBps;
    /// @notice Receiver of accrued fee shares.
    address public feeRecipient;
    /// @notice Timestamp of the last fee settlement.
    uint64 public lastFeeAccrual;

    // ----------------------------------------------------------------- events
    event SleeveAdded(address indexed sleeve, uint96 cap);
    event SleeveRemoved(address indexed sleeve);
    event SleeveCapSet(address indexed sleeve, uint96 cap);
    event Allocated(address indexed sleeve, uint256 assets);
    event Deallocated(address indexed sleeve, uint256 requested, uint256 withdrawn);
    event FeeSet(uint16 feeBps);
    event FeeRecipientSet(address indexed feeRecipient);
    event FeeAccrued(uint256 feeShares);

    // ----------------------------------------------------------------- errors
    error ZeroAddress();
    error SleeveAlreadyActive(address sleeve);
    error SleeveNotActive(address sleeve);
    error SleeveNotEmpty(address sleeve);
    error TooManySleeves();
    error SleeveCapExceeded(address sleeve, uint256 sleeveAssets, uint256 cap);
    error FeeTooHigh(uint16 feeBps);

    constructor(IERC20 usdc, address admin, address feeRecipient_) ERC4626(usdc) ERC20("Alba USDC Vault", "albaUSDC") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        feeRecipient = feeRecipient_;
        lastFeeAccrual = uint64(block.timestamp);
    }

    // ------------------------------------------------------------- accounting

    /// @notice NAV: idle USDC held by the vault plus every sleeve's reported value.
    function totalAssets() public view override returns (uint256 assets) {
        assets = IERC20(asset()).balanceOf(address(this));
        uint256 n = sleeves.length;
        for (uint256 i; i < n; ++i) {
            assets += ISleeve(sleeves[i]).totalAssets();
        }
    }

    /// @notice Assets withdrawable right now: idle USDC plus what sleeves report
    /// as instantly liquid. This — not NAV — bounds maxWithdraw/maxRedeem.
    function liquidAssets() public view returns (uint256 liquid) {
        liquid = IERC20(asset()).balanceOf(address(this));
        uint256 n = sleeves.length;
        for (uint256 i; i < n; ++i) {
            liquid += ISleeve(sleeves[i]).liquidAssets();
        }
    }

    /// @notice Number of registered sleeves.
    function sleeveCount() external view returns (uint256) {
        return sleeves.length;
    }

    // ------------------------------------------------------------ 4626 limits

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /// @inheritdoc ERC4626
    function maxMint(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /// @inheritdoc ERC4626
    function maxWithdraw(address owner) public view override returns (uint256) {
        return paused() ? 0 : Math.min(super.maxWithdraw(owner), liquidAssets());
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override returns (uint256) {
        return paused() ? 0 : Math.min(balanceOf(owner), _convertToShares(liquidAssets(), Math.Rounding.Floor));
    }

    // ------------------------------------------------------------- user flows

    /// @inheritdoc ERC4626
    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256) {
        _accrueFee();
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626
    function mint(uint256 shares, address receiver) public override whenNotPaused returns (uint256) {
        _accrueFee();
        return super.mint(shares, receiver);
    }

    /// @inheritdoc ERC4626
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256)
    {
        _accrueFee();
        return super.withdraw(assets, receiver, owner);
    }

    /// @inheritdoc ERC4626
    function redeem(uint256 shares, address receiver, address owner) public override whenNotPaused returns (uint256) {
        _accrueFee();
        return super.redeem(shares, receiver, owner);
    }

    /// @dev Pulls from sleeves (registry order) when idle USDC cannot cover a
    /// withdrawal; maxWithdraw already guaranteed the liquidity exists.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) {
            uint256 missing = assets - idle;
            uint256 n = sleeves.length;
            for (uint256 i; i < n && missing != 0; ++i) {
                missing -= ISleeve(sleeves[i]).withdraw(missing);
            }
        }
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // -------------------------------------------------------------------- fee

    /// @dev Fee shares that would be minted if settlement ran now. Views fold
    /// this into conversions so previews/limits match post-settlement execution.
    function _pendingFeeShares() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastFeeAccrual;
        if (elapsed == 0 || feeBps == 0) return 0;
        uint256 assets = totalAssets();
        uint256 feeAssets = assets.mulDiv(uint256(feeBps) * elapsed, BPS * 365 days);
        if (feeAssets == 0) return 0;
        if (feeAssets >= assets) feeAssets = assets - 1; // unreachable below ~20y idle; keeps math safe
        // Dilution such that feeRecipient can redeem exactly feeAssets.
        return feeAssets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), assets - feeAssets + 1, Math.Rounding.Floor);
    }

    /// @dev Settle the management fee as share dilution to feeRecipient.
    function _accrueFee() internal {
        uint256 feeShares = _pendingFeeShares();
        lastFeeAccrual = uint64(block.timestamp);
        if (feeShares != 0) {
            _mint(feeRecipient, feeShares);
            emit FeeAccrued(feeShares);
        }
    }

    /// @dev Fee-aware conversions: pending fee dilution counts as supply.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(totalSupply() + _pendingFeeShares() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /// @dev See {_convertToShares}.
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + _pendingFeeShares() + 10 ** _decimalsOffset(), rounding);
    }

    /// @dev 10^6 virtual-share offset: inflation-attack cost is a millionfold
    /// the victim's rounding loss. Shares have 12 decimals (USDC 6 + 6).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ------------------------------------------------------------- allocation

    /// @notice Move `assets` of idle USDC into `sleeve`, bounded by its cap.
    /// @param sleeve Registered sleeve to fund.
    /// @param assets Amount of USDC to allocate.
    function allocate(address sleeve, uint256 assets) external onlyRole(ALLOCATOR_ROLE) whenNotPaused {
        SleeveConfig memory cfg = sleeveConfig[sleeve];
        if (!cfg.active) revert SleeveNotActive(sleeve);
        IERC20(asset()).forceApprove(sleeve, assets);
        ISleeve(sleeve).deposit(assets);
        uint256 sleeveAssets = ISleeve(sleeve).totalAssets();
        if (sleeveAssets > cfg.cap) revert SleeveCapExceeded(sleeve, sleeveAssets, cfg.cap);
        emit Allocated(sleeve, assets);
    }

    /// @notice Pull up to `assets` USDC back from `sleeve` into the vault.
    /// @dev Deliberately callable while paused: recovery moves funds toward the
    /// vault, never away from it.
    /// @param sleeve Registered sleeve to defund.
    /// @param assets Amount requested; the sleeve returns what it can.
    /// @return withdrawn Amount actually returned.
    function deallocate(address sleeve, uint256 assets) external onlyRole(ALLOCATOR_ROLE) returns (uint256 withdrawn) {
        if (!sleeveConfig[sleeve].active) revert SleeveNotActive(sleeve);
        withdrawn = ISleeve(sleeve).withdraw(assets);
        emit Deallocated(sleeve, assets, withdrawn);
    }

    // --------------------------------------------------------------- curation

    /// @notice Register a sleeve with an allocation cap. Sleeves are trusted
    /// code — this call sits behind the admin timelock by deployment policy.
    /// @param sleeve Sleeve contract implementing {ISleeve}.
    /// @param cap Max sleeve.totalAssets() enforced on allocation.
    function addSleeve(address sleeve, uint96 cap) external onlyRole(CURATOR_ROLE) {
        if (sleeve == address(0)) revert ZeroAddress();
        if (sleeveConfig[sleeve].active) revert SleeveAlreadyActive(sleeve);
        if (sleeves.length >= MAX_SLEEVES) revert TooManySleeves();
        sleeves.push(sleeve);
        sleeveConfig[sleeve] = SleeveConfig({active: true, cap: cap});
        emit SleeveAdded(sleeve, cap);
    }

    /// @notice Deregister an emptied sleeve.
    /// @param sleeve Sleeve to remove; must report zero totalAssets.
    function removeSleeve(address sleeve) external onlyRole(CURATOR_ROLE) {
        if (!sleeveConfig[sleeve].active) revert SleeveNotActive(sleeve);
        if (ISleeve(sleeve).totalAssets() != 0) revert SleeveNotEmpty(sleeve);
        uint256 n = sleeves.length;
        for (uint256 i; i < n; ++i) {
            if (sleeves[i] == sleeve) {
                sleeves[i] = sleeves[n - 1];
                sleeves.pop();
                break;
            }
        }
        delete sleeveConfig[sleeve];
        emit SleeveRemoved(sleeve);
    }

    /// @notice Update a sleeve's allocation cap (checked on future allocations).
    /// @param sleeve Registered sleeve.
    /// @param cap New cap in asset units.
    function setSleeveCap(address sleeve, uint96 cap) external onlyRole(CURATOR_ROLE) {
        if (!sleeveConfig[sleeve].active) revert SleeveNotActive(sleeve);
        sleeveConfig[sleeve].cap = cap;
        emit SleeveCapSet(sleeve, cap);
    }

    /// @notice Set the management fee (bps/year); settles the old fee first.
    /// @param newFeeBps New fee, at most {MAX_FEE_BPS}.
    function setFee(uint16 newFeeBps) external onlyRole(CURATOR_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps);
        if (newFeeBps != 0 && feeRecipient == address(0)) revert ZeroAddress();
        _accrueFee();
        feeBps = newFeeBps;
        emit FeeSet(newFeeBps);
    }

    /// @notice Change the fee recipient; accrued-to-date fees settle to the old one.
    /// @param newFeeRecipient New recipient; nonzero while a fee is set.
    function setFeeRecipient(address newFeeRecipient) external onlyRole(CURATOR_ROLE) {
        if (newFeeRecipient == address(0) && feeBps != 0) revert ZeroAddress();
        _accrueFee();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientSet(newFeeRecipient);
    }

    // ------------------------------------------------------------------ pause

    /// @notice Guardian circuit breaker: freezes deposits, withdrawals and allocation.
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Admin-only resume (a compromised guardian must not unpause).
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
