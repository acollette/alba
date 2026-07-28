// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CollateralParams, IMidnight, Market, Offer} from "../../src/vault/interfaces/IMidnight.sol";

/// @notice Shared fixture for Midnight fork tests. The order book is OFF-CHAIN,
/// so a pinned block alone contains no offers: the fixture is (pinned block,
/// API snapshot captured at the same wall-clock moment). Raw snapshot + capture
/// metadata live in `fixtures/midnight-asks-49219332.json`; the top ask is
/// transcribed here field-for-field. See fixtures/README.md for regeneration.
abstract contract MidnightForkBase is Test {
    address constant MIDNIGHT = 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant CBBTC_ORACLE = 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9;
    address constant SETTER_RATIFIER = 0x800B5F12A61B8198a5a6EfD794Cac6699B294d63;

    /// @dev cbBTC/USDC 2026-08-28T15:00Z market (deepest book at capture).
    bytes32 constant MARKET_ID = 0x05959752fdeff325962b9d263edb421efc6e2186a49360dba6c32e86ebf6c84c;
    uint256 constant MATURITY = 1_787_929_200;

    /// @dev Block captured atomically with the API snapshot (ts 1,785,228,011,
    /// inside every fixture offer's [start, expiry] window — frozen forever).
    uint256 constant FORK_BLOCK = 49_219_332;

    /// @dev Top ask: maker 0xd418…6ee4, tick 4516 => price = 0.9966842e18,
    /// remaining max_assets 100,000e6, takeable ≈ 78,317e6 units at capture.
    uint256 constant TOP_TICK = 4516;
    uint256 constant TOP_PRICE_WAD = 996_684_200_000_000_000; // tickToPrice(4516)
    address constant TOP_MAKER = 0xd418224aE3c510B645112FD9275CCFD50F996ee4;
    uint128 constant TOP_MAX_ASSETS = 100_000e6;

    function _market() internal pure returns (Market memory m) {
        m.chainId = 8453;
        m.midnight = MIDNIGHT;
        m.loanToken = USDC;
        m.collateralParams = new CollateralParams[](1);
        m.collateralParams[0] =
            CollateralParams({token: CBBTC, lltv: 0.86e18, liquidationCursor: 0.3e18, oracle: CBBTC_ORACLE});
        m.maturity = MATURITY;
        m.rcfThreshold = 3_000e6;
        m.enterGate = address(0);
        m.liquidatorGate = address(0);
    }

    function _topAsk() internal pure returns (Offer memory o) {
        o.market = _market();
        o.buy = false;
        o.maker = TOP_MAKER;
        o.start = 1_785_123_075;
        o.expiry = 1_785_232_644;
        o.tick = TOP_TICK;
        o.group = 0x72e9ceea711ee7a654cff189d8ade0f4fcc0b7117e24e5305f8c4cb8c80d1784;
        o.callback = address(0);
        o.callbackData = "";
        o.receiverIfMakerIsSeller = TOP_MAKER;
        o.ratifier = SETTER_RATIFIER;
        o.reduceOnly = false;
        o.maxUnits = 0;
        o.maxAssets = TOP_MAX_ASSETS;
        o.continuousFeeCap = type(uint256).max;
    }

    /// @dev Best takeable BID at capture (maker 0x6c51…28b9, tick 4508 =>
    /// price = 0.9965497e18, remaining max_assets 500e6): the standing lender
    /// demand {MidnightSleeve.emergencySell} sells into.
    uint256 constant BID_PRICE_WAD = 996_549_700_000_000_000; // tickToPrice(4508)

    function _topBid() internal pure returns (Offer memory o) {
        o.market = _market();
        o.buy = true;
        o.maker = 0x6c515B41bFBEe0aA754F306098Ba005152c928b9;
        o.start = 1_785_191_379;
        o.expiry = 1_785_295_054;
        o.tick = 4508;
        o.group = 0x4de9ed4e5a4035a459b5ec264cd4b0534aa3e877ab9ca3ba0d2b193ca17266fb;
        o.receiverIfMakerIsSeller = address(0);
        o.ratifier = SETTER_RATIFIER;
        o.maxUnits = 0;
        o.maxAssets = 500e6;
        o.continuousFeeCap = type(uint256).max;
    }

    function _topBidRatifierData() internal pure returns (bytes memory) {
        return hex"7d1fe9ef787b3f2096ca995cdef620c2a1aefaeea92c1cd1f0f166af4a3b14f8"
            hex"0000000000000000000000000000000000000000000000000000000000000001"
            hex"0000000000000000000000000000000000000000000000000000000000000060"
            hex"0000000000000000000000000000000000000000000000000000000000000005"
            hex"31196d72881f65dba3b4312f2871c9602132ce3400335e4640521d2c939b0c6d"
            hex"3d858dfee0d36da67e4d81b58dc38182e83bb42599294a2bba6aba409c54f902"
            hex"1938b0b7c511ebb540141beb3acf850fe1a85eddae4ec7728ab1765582c6aa6d"
            hex"283ebc8cd953fde4f55ccc518c4b84906abb52e459a825afac147eb7bc4ea33d"
            hex"b02af3bc5a3c26cc0af63734d658502795139ed41f84974a1f471b02e59d485b";
    }

    /// @dev SetterRatifier proof: abi.encode(root, leafIndex, bytes32[] proof).
    function _topRatifierData() internal pure returns (bytes memory) {
        return hex"7a1115ee77f0cadecbb3ab7cfa7a7144ff95088bc778940fbc9520bd22a0dfe4"
            hex"0000000000000000000000000000000000000000000000000000000000000005"
            hex"0000000000000000000000000000000000000000000000000000000000000060"
            hex"0000000000000000000000000000000000000000000000000000000000000005"
            hex"57390d17e360e3a359df3575322d725f80ceeb02ee747a20c621fa1a16f851c0"
            hex"ba8fa3889dcc7fea11cc348407434ea40328b5e872c317ecd8edb15debb3d1ce"
            hex"aa953d6c16a021cec76f362119b68d7765626e0c41e68cece24154fd0f670358"
            hex"205db16948608fa9e9a2253b445e5e2306f044207f5c47cc58fd8a914f37b4c6"
            hex"825e58e6f871a351c22fec122add80185d6f6b5331fe3cd0bbac802b3bb79279";
    }

    function _selectFork() internal {
        vm.createSelectFork(vm.envOr("BASE_MAINNET_RPC", string("https://mainnet.base.org")), FORK_BLOCK);
    }
}

/// @notice CANARY — must pass before any other Midnight fork work is trusted.
/// The deployed Midnight bytecode uses the Osaka `clz` opcode (plus Cancun
/// mcopy/tload/tstore); executing it needs `evm_version = "osaka"` (set in
/// foundry.toml) AND forge >= 1.5.x — forge 1.0.0 halts mid-`take()` with
/// OpcodeNotFound (view getters may still pass; only a real fill proves the
/// spec). This test also pins that the market id binds to the Market struct
/// the way the sleeve assumes.
contract MidnightForkCanaryTest is MidnightForkBase {
    function setUp() public {
        _selectFork();
    }

    function test_Fork_Canary_ViewsExecute() public view {
        // Any successful call proves opcode support; these also pin semantics.
        assertGe(IMidnight(MIDNIGHT).withdrawable(MARKET_ID), 0);
        Market memory m = IMidnight(MIDNIGHT).toMarket(MARKET_ID);
        assertEq(keccak256(abi.encode(m)), keccak256(abi.encode(_market())), "market id <-> struct binding");
        (uint128 credit, uint128 pendingFee,) = IMidnight(MIDNIGHT).updatePositionView(m, MARKET_ID, TOP_MAKER);
        assertGe(uint256(credit) + pendingFee, 0);
    }

    function test_Fork_Canary_RawTakeExecutes() public {
        address taker = makeAddr("taker");
        deal(USDC, taker, 100_000e6);
        vm.startPrank(taker);
        (bool ok,) = USDC.call(abi.encodeWithSignature("approve(address,uint256)", MIDNIGHT, type(uint256).max));
        assertTrue(ok);
        (uint256 buyerAssets,) =
            IMidnight(MIDNIGHT).take(_topAsk(), _topRatifierData(), 10_000e6, taker, address(0), address(0), "");
        vm.stopPrank();
        // price ≈ 0.99667, settlement fee 0 at pin => pay slightly under par.
        assertApproxEqRel(buyerAssets, 10_000e6 * TOP_PRICE_WAD / 1e18, 0.0001e18);
        assertEq(IMidnight(MIDNIGHT).credit(MARKET_ID, taker), 10_000e6);
    }
}
