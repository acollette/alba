// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {TokenCustomDecimalsMock} from "@1inch/solidity-utils/contracts/mocks/TokenCustomDecimalsMock.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AlbaVault} from "../../src/vault/AlbaVault.sol";
import {MetaMorphoSleeve} from "../../src/vault/MetaMorphoSleeve.sol";

/// @notice Stand-in for a MetaMorpho vault: plain OZ 4626 with a settable
/// instant-liquidity limit (simulates high market utilization / freezes).
contract Mock4626Target is ERC4626 {
    uint256 public liquid = type(uint256).max;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock MetaMorpho USDC", "mmUSDC") {}

    function setLiquid(uint256 liquid_) external {
        liquid = liquid_;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), liquid);
    }
}

/// @notice Shared deployment: 6-decimals USDC mock, vault, roles, two sleeves
/// (registered by tests that need them).
abstract contract VaultTestBase is Test {
    TokenCustomDecimalsMock internal usdc;
    AlbaVault internal vault;
    Mock4626Target internal targetA;
    Mock4626Target internal targetB;
    MetaMorphoSleeve internal sleeveA;
    MetaMorphoSleeve internal sleeveB;

    address internal admin = makeAddr("admin");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        usdc = new TokenCustomDecimalsMock("USD Coin", "USDC", 0, 6);
        vault = new AlbaVault(usdc, admin, feeRecipient);
        targetA = new Mock4626Target(usdc);
        targetB = new Mock4626Target(usdc);
        sleeveA = new MetaMorphoSleeve(address(vault), targetA);
        sleeveB = new MetaMorphoSleeve(address(vault), targetB);

        vm.startPrank(admin);
        vault.grantRole(vault.CURATOR_ROLE(), curator);
        vault.grantRole(vault.ALLOCATOR_ROLE(), allocator);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);
        vm.stopPrank();
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        usdc.mint(user, assets);
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        shares = vault.deposit(assets, user);
        vm.stopPrank();
    }

    function _addSleeves(uint96 capA, uint96 capB) internal {
        vm.startPrank(curator);
        vault.addSleeve(address(sleeveA), capA);
        vault.addSleeve(address(sleeveB), capB);
        vm.stopPrank();
    }
}
