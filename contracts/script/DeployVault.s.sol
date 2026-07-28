// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {TokenCustomDecimalsMock} from "@1inch/solidity-utils/contracts/mocks/TokenCustomDecimalsMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AlbaVault} from "../src/vault/AlbaVault.sol";
import {MetaMorphoSleeve} from "../src/vault/MetaMorphoSleeve.sol";
import {MidnightSleeve} from "../src/vault/MidnightSleeve.sol";
import {IMidnight} from "../src/vault/interfaces/IMidnight.sol";
import {MockMidnight} from "../test/vault/MockMidnight.sol";
import {Mock4626Target} from "../test/vault/VaultTestBase.sol";

/// @notice Full v1 vault-stack deployment (VAULT_PLAN.md §6): AlbaVault +
/// MetaMorphoSleeve (buffer) + MidnightSleeve, sleeve registration in
/// withdrawal-pull order (buffer FIRST), curator caps from env, and role
/// handoff — DEFAULT_ADMIN to the ADMIN multisig+timelock, CURATOR/ALLOCATOR/
/// GUARDIAN to their env addresses, every bootstrap role renounced by the
/// deployer at the end (asserted, not assumed).
///
/// Profiles, keyed on chainid:
/// - Base mainnet (8453): canonical USDC + Midnight core; MetaMorpho target
///   from METAMORPHO_TARGET (default: Moonwell Flagship USDC — the vault the
///   fork suite tests against).
/// - Local/anvil (anything else): deploys mock USDC, a mock 4626 target and
///   the test-suite MockMidnight, so the identical wiring path can be
///   rehearsed and the frontend pointed at a real local stack.
///
/// Initial pause state (documented decision): on mainnet the vault deploys
/// PAUSED — deposits stay closed until the ADMIN multisig calls unpause(),
/// which doubles as the proof that admin control was handed off correctly
/// (unpause is DEFAULT_ADMIN-only). Locally it deploys unpaused. Override
/// either way with PAUSE_ON_DEPLOY=true|false.
///
/// Midnight markets are deliberately NOT allow-listed here: market selection
/// is an operational curator action (live maturities, per-market caps) — see
/// md-files/VAULT_RUNBOOK.md.
///
/// Env (see VAULT_RUNBOOK.md for the full checklist):
///   PRIVATE_KEY          deployer (bootstrap-only; holds nothing afterwards)
///   ADMIN                DEFAULT_ADMIN — multisig behind a 24-48h timelock
///   CURATOR / ALLOCATOR / GUARDIAN   role addresses (allocator = bot hot key)
///   FEE_RECIPIENT        optional, default 0 (fee stays 0 until curator sets it)
///   METAMORPHO_TARGET    optional (mainnet default: Moonwell Flagship USDC)
///   BUFFER_CAP / MIDNIGHT_CAP        sleeve caps, USDC 6-dec (guarded-launch
///                                    defaults: 75k / 25k)
///   MAX_BUY_ASSETS       per-buy cost cap for MidnightSleeve (default 5k)
///   MIN_YIELD_WAD        annualized simple-yield floor, WAD (default 3%)
///   PAUSE_ON_DEPLOY      optional bool, default = (chainid == 8453)
contract DeployVault is Script {
    // -------------------------------------------- Base mainnet canonical set
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MIDNIGHT_BASE = 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A;
    /// @dev Moonwell Flagship USDC — the MetaMorpho vault the T4 fork suite
    /// validates against; curator risk choice per VAULT_PLAN.md §8.
    address constant MOONWELL_USDC = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bool mainnet = block.chainid == 8453;

        address admin = vm.envAddress("ADMIN");
        address curator = vm.envAddress("CURATOR");
        address allocator = vm.envAddress("ALLOCATOR");
        address guardian = vm.envAddress("GUARDIAN");
        address feeRecipient = vm.envOr("FEE_RECIPIENT", address(0));

        uint96 bufferCap = uint96(vm.envOr("BUFFER_CAP", uint256(75_000e6)));
        uint96 midnightCap = uint96(vm.envOr("MIDNIGHT_CAP", uint256(25_000e6)));
        uint256 maxBuyAssets = vm.envOr("MAX_BUY_ASSETS", uint256(5_000e6));
        uint256 minYieldWad = vm.envOr("MIN_YIELD_WAD", uint256(0.03e18));
        bool pauseOnDeploy = vm.envOr("PAUSE_ON_DEPLOY", mainnet);

        vm.startBroadcast(pk);

        // Profile: canonical addresses on mainnet, fresh mocks elsewhere.
        address usdc;
        address midnight;
        address target;
        if (mainnet) {
            usdc = USDC_BASE;
            midnight = MIDNIGHT_BASE;
            target = vm.envOr("METAMORPHO_TARGET", MOONWELL_USDC);
        } else {
            usdc = address(new TokenCustomDecimalsMock("USD Coin", "USDC", 0, 6));
            midnight = address(new MockMidnight(IERC20(usdc)));
            target = address(new Mock4626Target(IERC20(usdc)));
        }

        // Deploy: deployer is bootstrap DEFAULT_ADMIN + CURATOR, both
        // renounced below once wiring is complete.
        AlbaVault vault = new AlbaVault(IERC20(usdc), deployer, feeRecipient);
        MetaMorphoSleeve buffer = new MetaMorphoSleeve(address(vault), IERC4626(target));
        MidnightSleeve sleeve = new MidnightSleeve(address(vault), IMidnight(midnight));

        // Registry order IS the withdrawal-pull order: buffer FIRST, so user
        // exits drain the floating buffer before touching Midnight claims.
        vault.grantRole(vault.CURATOR_ROLE(), deployer);
        vault.addSleeve(address(buffer), bufferCap);
        vault.addSleeve(address(sleeve), midnightCap);
        sleeve.setMaxBuyAssets(maxBuyAssets);
        sleeve.setMinYield(minYieldWad);

        // Operating roles, then the pause-state choice, then handoff.
        vault.grantRole(vault.CURATOR_ROLE(), curator);
        vault.grantRole(vault.ALLOCATOR_ROLE(), allocator);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);
        if (pauseOnDeploy) {
            vault.grantRole(vault.GUARDIAN_ROLE(), deployer);
            vault.pause(); // ADMIN's unpause() is the go-live switch
            vault.renounceRole(vault.GUARDIAN_ROLE(), deployer);
        }
        vault.renounceRole(vault.CURATOR_ROLE(), deployer);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), admin);
        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        // Post-conditions — fail the broadcast log loudly if wiring is off.
        require(vault.sleeves(0) == address(buffer), "registry order: buffer must be first");
        require(vault.sleeves(1) == address(sleeve), "registry order: midnight second");
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "admin not set");
        require(!vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer), "deployer kept admin");
        require(!vault.hasRole(vault.CURATOR_ROLE(), deployer), "deployer kept curator");
        require(vault.getRoleMemberCount(vault.DEFAULT_ADMIN_ROLE()) == 1, "admin must be sole");
        require(vault.paused() == pauseOnDeploy, "pause state mismatch");

        // ------------------------------------------------------- address book
        console.log("=== AlbaVault v1 address book (chainid %s) ===", block.chainid);
        console.log("VAULT (albaUSDC):   ", address(vault));
        console.log("BUFFER_SLEEVE:      ", address(buffer));
        console.log("MIDNIGHT_SLEEVE:    ", address(sleeve));
        console.log("USDC:               ", usdc);
        console.log("MIDNIGHT_CORE:      ", midnight);
        console.log("METAMORPHO_TARGET:  ", target);
        console.log("ADMIN:              ", admin);
        console.log("CURATOR:            ", curator);
        console.log("ALLOCATOR:          ", allocator);
        console.log("GUARDIAN:           ", guardian);
        console.log("FEE_RECIPIENT:      ", feeRecipient);
        console.log("buffer cap:         ", bufferCap);
        console.log("midnight cap:       ", midnightCap);
        console.log("max buy assets:     ", maxBuyAssets);
        console.log("min yield (WAD):    ", minYieldWad);
        console.log("paused at deploy:   ", pauseOnDeploy);
    }
}
