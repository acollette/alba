// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {TokenCustomDecimalsMock} from "@1inch/solidity-utils/contracts/mocks/TokenCustomDecimalsMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AlbaVault} from "../../src/vault/AlbaVault.sol";
import {MetaMorphoSleeve} from "../../src/vault/MetaMorphoSleeve.sol";
import {MidnightSleeve} from "../../src/vault/MidnightSleeve.sol";
import {IMidnight, Market, Offer} from "../../src/vault/interfaces/IMidnight.sol";
import {MockMidnight} from "./MockMidnight.sol";
import {Mock4626Target} from "./VaultTestBase.sol";

/// @notice T3 — share-price monotonicity modulo fees under random deposit/
/// withdraw/redeem/allocate/deallocate/donate/warp interleavings, now
/// including the Midnight sleeve's bond lifecycle: buy (NAV-neutral at cost),
/// accretion (warp), pool funding + redemption (NAV up), and vault pulls of
/// claimable par. Fee is 0 so the invariant is strict. Slashes and
/// emergency sells legitimately mark NAV down and are exercised in
/// MidnightSleeve.t.sol instead of here.
contract VaultHandler is Test {
    AlbaVault public immutable vault;
    TokenCustomDecimalsMock public immutable usdc;
    MetaMorphoSleeve public immutable sleeve;
    MidnightSleeve public immutable midSleeve;
    MockMidnight public immutable mid;
    bytes32 public immutable marketId;
    uint256 public immutable maturity;

    Market internal mkt;
    address internal actor = makeAddr("actor");
    bool public priceDropped;

    constructor(
        AlbaVault vault_,
        TokenCustomDecimalsMock usdc_,
        MetaMorphoSleeve sleeve_,
        MidnightSleeve midSleeve_,
        MockMidnight mid_,
        Market memory mkt_
    ) {
        vault = vault_;
        usdc = usdc_;
        sleeve = sleeve_;
        midSleeve = midSleeve_;
        mid = mid_;
        mkt = mkt_;
        marketId = keccak256(abi.encode(mkt_));
        maturity = mkt_.maturity;
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

    // ------------------------------------------------ Midnight bond lifecycle

    function allocateMid(uint256 assets) external monotonic {
        assets = bound(assets, 0, usdc.balanceOf(address(vault)));
        if (assets == 0) return;
        vault.allocate(address(midSleeve), assets);
    }

    function deallocateMid(uint256 assets) external monotonic {
        assets = bound(assets, 0, midSleeve.liquidAssets());
        if (assets == 0) return;
        vault.deallocate(address(midSleeve), assets);
    }

    function buyPaper(uint256 units, uint256 priceWad) external monotonic {
        if (block.timestamp >= maturity) return; // no post-maturity issuance
        priceWad = bound(priceWad, 0.95e18, 1e18);
        uint256 idle = usdc.balanceOf(address(midSleeve));
        uint256 maxUnits = idle * 1e18 / priceWad;
        if (maxUnits == 0) return;
        units = bound(units, 1, maxUnits);
        mid.setPrice(priceWad);
        midSleeve.buy(_ask(), "", units, type(uint256).max); // handler is allocator
    }

    function fundAndRedeem(uint256 units) external monotonic {
        uint256 credit = mid.credit(marketId, address(midSleeve));
        uint256 pool = mid.withdrawable(marketId);
        if (credit <= pool) return;
        units = bound(units, 1, credit - pool);
        usdc.mint(address(mid), units);
        mid.fund(marketId, uint128(units));
        midSleeve.redeem(marketId);
    }

    function _ask() internal view returns (Offer memory o) {
        o.market = mkt;
        o.buy = false;
    }
}

contract VaultInvariantTest is Test {
    AlbaVault vault;
    TokenCustomDecimalsMock usdc;
    Mock4626Target target;
    MetaMorphoSleeve sleeve;
    MockMidnight mid;
    MidnightSleeve midSleeve;
    VaultHandler handler;

    function setUp() public {
        usdc = new TokenCustomDecimalsMock("USD Coin", "USDC", 0, 6);
        vault = new AlbaVault(usdc, address(this), address(0));
        target = new Mock4626Target(usdc);
        sleeve = new MetaMorphoSleeve(address(vault), target);
        mid = new MockMidnight(IERC20(address(usdc)));
        midSleeve = new MidnightSleeve(address(vault), IMidnight(address(mid)));

        vault.grantRole(vault.CURATOR_ROLE(), address(this));
        vault.addSleeve(address(sleeve), type(uint96).max); // buffer first
        vault.addSleeve(address(midSleeve), type(uint96).max);

        Market memory mkt;
        mkt.chainId = block.chainid;
        mkt.midnight = address(mid);
        mkt.loanToken = address(usdc);
        mkt.maturity = block.timestamp + 90 days;
        bytes32 id = mid.touch(mkt);
        midSleeve.allowMarket(id, type(uint128).max);
        midSleeve.setMaxBuyAssets(type(uint256).max);

        handler = new VaultHandler(vault, usdc, sleeve, midSleeve, mid, mkt);
        vault.grantRole(vault.ALLOCATOR_ROLE(), address(handler));
        targetContract(address(handler));
    }

    /// @dev With fee = 0 and no lossy actions (no slash, no emergency sell),
    /// assets-per-share never falls: buys at cost, linear accretion, par
    /// redemptions and early claim pulls only hold or raise the price.
    function invariant_SharePriceMonotonicModuloFees() public view {
        assertFalse(handler.priceDropped());
    }

    /// @dev The vault never claims more instant liquidity than it has value.
    function invariant_LiquidNeverExceedsTotal() public view {
        assertLe(vault.liquidAssets(), vault.totalAssets() + 1);
    }

    /// @dev The Midnight book never carries paper above face value.
    function invariant_MidnightBookNeverExceedsFace() public view {
        (uint128 units,,,,,,) = midSleeve.book(handler.marketId());
        assertLe(midSleeve.totalAssets(), usdc.balanceOf(address(midSleeve)) + units);
    }
}
