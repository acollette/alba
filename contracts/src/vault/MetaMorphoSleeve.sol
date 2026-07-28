// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISleeve} from "./interfaces/ISleeve.sol";

/// @title MetaMorphoSleeve — thin 4626-in-4626 adapter for AlbaVault
/// @notice Parks vault USDC in one curator-chosen MetaMorpho vault (the
/// floating-rate liquidity buffer). Stateless beyond immutables: the sleeve's
/// book IS its target-share balance. The target is trusted by curation — it is
/// fixed at construction and the sleeve is only registered behind the vault's
/// admin timelock (see {ISleeve}).
contract MetaMorphoSleeve is ISleeve {
    using SafeERC20 for IERC20;

    /// @notice The AlbaVault this sleeve serves; sole authorized caller.
    address public immutable VAULT;
    /// @notice The MetaMorpho (ERC-4626) vault the sleeve deposits into.
    IERC4626 public immutable TARGET;
    /// @notice Underlying asset (USDC), read from the target.
    IERC20 public immutable ASSET;

    error NotVault();

    /// @param vault The AlbaVault address.
    /// @param target The MetaMorpho vault to adapt.
    constructor(address vault, IERC4626 target) {
        VAULT = vault;
        TARGET = target;
        ASSET = IERC20(target.asset());
        ASSET.forceApprove(address(target), type(uint256).max);
    }

    modifier onlyVault() {
        if (msg.sender != VAULT) revert NotVault();
        _;
    }

    /// @inheritdoc ISleeve
    function deposit(uint256 assets) external onlyVault {
        ASSET.safeTransferFrom(VAULT, address(this), assets);
        TARGET.deposit(assets, address(this));
    }

    /// @inheritdoc ISleeve
    function withdraw(uint256 assets) external onlyVault returns (uint256 withdrawn) {
        uint256 idle = ASSET.balanceOf(address(this));
        if (assets > idle) {
            uint256 fromTarget = Math.min(assets - idle, TARGET.maxWithdraw(address(this)));
            if (fromTarget != 0) TARGET.withdraw(fromTarget, address(this), address(this));
        }
        withdrawn = Math.min(assets, ASSET.balanceOf(address(this)));
        if (withdrawn != 0) ASSET.safeTransfer(VAULT, withdrawn);
    }

    /// @inheritdoc ISleeve
    function totalAssets() external view returns (uint256) {
        return ASSET.balanceOf(address(this)) + TARGET.previewRedeem(TARGET.balanceOf(address(this)));
    }

    /// @inheritdoc ISleeve
    function liquidAssets() external view returns (uint256) {
        return ASSET.balanceOf(address(this)) + TARGET.maxWithdraw(address(this));
    }
}
