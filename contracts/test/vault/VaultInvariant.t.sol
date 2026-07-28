// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {TokenCustomDecimalsMock} from "@1inch/solidity-utils/contracts/mocks/TokenCustomDecimalsMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AlbaVault} from "../../src/vault/AlbaVault.sol";
import {MetaMorphoSleeve} from "../../src/vault/MetaMorphoSleeve.sol";
import {Mock4626Target} from "./VaultTestBase.sol";

/// @notice T3 skeleton — share-price monotonicity modulo fees under random
/// deposit/withdraw/redeem/allocate/deallocate/donate/warp interleavings.
/// Fee is kept at 0 here so the invariant is strict; WS3 extends this handler
/// with bond buy/mature accretion actions and a fee-adjusted price index.
contract VaultHandler is Test {
    AlbaVault public immutable vault;
    TokenCustomDecimalsMock public immutable usdc;
    MetaMorphoSleeve public immutable sleeve;

    address internal actor = makeAddr("actor");
    bool public priceDropped;

    constructor(AlbaVault vault_, TokenCustomDecimalsMock usdc_, MetaMorphoSleeve sleeve_) {
        vault = vault_;
        usdc = usdc_;
        sleeve = sleeve_;
    }

    function _price() internal view returns (uint256) {
        return vault.convertToAssets(1e12); // assets per whole share
    }

    modifier monotonic() {
        uint256 p0 = _price();
        _;
        if (_price() < p0) priceDropped = true;
    }

    function deposit(uint256 assets) external monotonic {
        assets = bound(assets, 1, 10_000_000e6);
        usdc.mint(actor, assets);
        vm.startPrank(actor);
        usdc.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();
    }

    function withdraw(uint256 assets) external monotonic {
        assets = bound(assets, 0, vault.maxWithdraw(actor));
        if (assets == 0) return;
        vm.prank(actor);
        vault.withdraw(assets, actor, actor);
    }

    function redeem(uint256 shares) external monotonic {
        shares = bound(shares, 0, vault.maxRedeem(actor));
        if (shares == 0) return;
        vm.prank(actor);
        vault.redeem(shares, actor, actor);
    }

    function allocate(uint256 assets) external monotonic {
        assets = bound(assets, 0, usdc.balanceOf(address(vault)));
        if (assets == 0) return;
        vault.allocate(address(sleeve), assets); // handler holds ALLOCATOR_ROLE
    }

    function deallocate(uint256 assets) external monotonic {
        assets = bound(assets, 0, sleeve.liquidAssets());
        if (assets == 0) return;
        vault.deallocate(address(sleeve), assets);
    }

    function donate(uint256 assets) external monotonic {
        assets = bound(assets, 1, 1_000e6);
        usdc.mint(address(vault), assets); // donations only push price up
    }

    function warp(uint256 dt) external monotonic {
        dt = bound(dt, 1, 30 days);
        skip(dt);
    }
}

contract VaultInvariantTest is Test {
    AlbaVault vault;
    TokenCustomDecimalsMock usdc;
    Mock4626Target target;
    MetaMorphoSleeve sleeve;
    VaultHandler handler;

    function setUp() public {
        usdc = new TokenCustomDecimalsMock("USD Coin", "USDC", 0, 6);
        vault = new AlbaVault(usdc, address(this), address(0));
        target = new Mock4626Target(usdc);
        sleeve = new MetaMorphoSleeve(address(vault), target);

        vault.grantRole(vault.CURATOR_ROLE(), address(this));
        vm.prank(address(this));
        vault.addSleeve(address(sleeve), type(uint96).max);

        handler = new VaultHandler(vault, usdc, sleeve);
        vault.grantRole(vault.ALLOCATOR_ROLE(), address(handler));
        targetContract(address(handler));
    }

    /// @dev With fee = 0 and no lossy strategies, assets-per-share never falls.
    function invariant_SharePriceMonotonicModuloFees() public view {
        assertFalse(handler.priceDropped());
    }

    /// @dev The vault never claims more instant liquidity than it has value.
    function invariant_LiquidNeverExceedsTotal() public view {
        assertLe(vault.liquidAssets(), vault.totalAssets() + 1);
    }
}
