#!/usr/bin/env bash
# Trigger-leg spike runbook. Prereq: contracts/.env populated, deployer funded on
# both chains (Hedera testnet HBAR + Base Sepolia ETH). Run steps in order.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

step="${1:-help}"

case "$step" in
  balances)
    echo "Base Sepolia: $(cast balance $DEPLOYER --rpc-url $BASE_SEPOLIA_RPC) wei"
    echo "Hedera:       $(cast balance $DEPLOYER --rpc-url $HEDERA_TESTNET_RPC) weibar"
    ;;

  deploy-receiver) # 1. dumb receiver on Base Sepolia
    forge create src/spike/SpikeReceiver.sol:SpikeReceiver \
      --rpc-url "$BASE_SEPOLIA_RPC" --private-key "$PRIVATE_KEY" --broadcast \
      --constructor-args "$AXELAR_GATEWAY_BASE_SEPOLIA"
    echo ">> put the deployed address into .env as SPIKE_RECEIVER_BASE_SEPOLIA"
    ;;

  deploy-trigger) # 2. trigger on Hedera testnet (dest addr = receiver as string)
    forge create src/spike/ChronosTriggerSpike.sol:ChronosTriggerSpike \
      --rpc-url "$HEDERA_TESTNET_RPC" --private-key "$PRIVATE_KEY" --broadcast \
      --constructor-args "$AXELAR_GATEWAY_HEDERA" "$AXELAR_GAS_SERVICE_HEDERA" \
        "base-sepolia" "$SPIKE_RECEIVER_BASE_SEPOLIA"
    echo ">> put the deployed address into .env as SPIKE_TRIGGER_HEDERA; then fund it:"
    echo "   cast send \$SPIKE_TRIGGER_HEDERA --value <hbar> --rpc-url \$HEDERA_TESTNET_RPC --private-key \$PRIVATE_KEY"
    ;;

  gas-estimate) # Axelar gas fee for hedera -> base-sepolia (in HBAR native units)
    curl -s -X POST https://testnet.api.gmp.axelarscan.io \
      -H 'Content-Type: application/json' \
      -d '{"method":"estimateGasFee","sourceChain":"hedera","destinationChain":"base-sepolia","gasLimit":200000}'
    echo
    ;;

  dispatch) # 3. manual end-to-end first (facilityId=1, drawId=1)
    GAS_TINYBARS="${2:?usage: dispatch <axelarGasTinybars>}"
    cast send "$SPIKE_TRIGGER_HEDERA" "dispatch(uint256,uint256,string,uint256)" \
      1 1 "SETTLE" "$GAS_TINYBARS" \
      --rpc-url "$HEDERA_TESTNET_RPC" --private-key "$PRIVATE_KEY"
    echo ">> track: https://testnet.axelarscan.io/address/$SPIKE_TRIGGER_HEDERA"
    ;;

  schedule) # 4. THE money shot: network-executed dispatch, no keeper
    DELAY="${2:-120}" GAS_TINYBARS="${3:?usage: schedule <delaySec> <axelarGasTinybars>}"
    EXPIRY=$(( $(date +%s) + DELAY ))
    cast send "$SPIKE_TRIGGER_HEDERA" \
      "scheduleDispatch(uint256,uint256,string,uint256,uint256,uint256)" \
      1 2 "SETTLE" "$EXPIRY" 2000000 "$GAS_TINYBARS" \
      --rpc-url "$HEDERA_TESTNET_RPC" --private-key "$PRIVATE_KEY"
    echo ">> schedule expiry: $EXPIRY ($(date -r $EXPIRY))"
    ;;

  watch) # 5. watch for TriggerReceived on Base Sepolia
    cast logs --rpc-url "$BASE_SEPOLIA_RPC" \
      --address "$SPIKE_RECEIVER_BASE_SEPOLIA" --from-block -2000 \
      "TriggerReceived(bytes32,string,string,uint256,uint256,string)"
    ;;

  *) grep -E '^  [a-z-]+\)' "$0" | sed 's/).*//' ;;
esac
