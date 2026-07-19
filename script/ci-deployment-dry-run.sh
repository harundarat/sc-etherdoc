#!/usr/bin/env bash
set -euo pipefail

readonly port="${ANVIL_PORT:-8545}"
readonly rpc_url="http://127.0.0.1:${port}"
readonly router="0x0000000000000000000000000000000000001001"
readonly link_token="0x0000000000000000000000000000000000001002"
readonly deployer="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
readonly governance="0x1000000000000000000000000000000000000001"
readonly issuer="0x1000000000000000000000000000000000000002"
readonly operator="0x1000000000000000000000000000000000000003"
readonly pauser="0x1000000000000000000000000000000000000004"

anvil --host 127.0.0.1 --port "$port" --chain-id 31337 --silent >"${TMPDIR:-/tmp}/etherdoc-anvil.log" 2>&1 &
anvil_pid=$!
cleanup() {
  kill "$anvil_pid" 2>/dev/null || true
  wait "$anvil_pid" 2>/dev/null || true
}
trap cleanup EXIT

ready=false
for _ in {1..40}; do
  if cast chain-id --rpc-url "$rpc_url" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 0.25
done
if [[ "$ready" != true ]]; then
  echo "Anvil did not become ready" >&2
  exit 1
fi

# Deployment preflight only requires code at the configured Router and LINK addresses.
cast rpc --rpc-url "$rpc_url" anvil_setCode "$router" 0x00 >/dev/null
cast rpc --rpc-url "$rpc_url" anvil_setCode "$link_token" 0x00 >/dev/null

starting_nonce="$(cast nonce --rpc-url "$rpc_url" "$deployer")"

NETWORK=local \
NETWORK_CONFIG_PATH=config/ci/anvil.json \
GOVERNANCE="$governance" \
INITIAL_ISSUER="$issuer" \
OPERATOR="$operator" \
PAUSER="$pauser" \
forge script script/EtherdocSenderScript.s.sol:EtherdocSenderScript \
  --rpc-url "$rpc_url" \
  --sender "$deployer"

NETWORK=local \
NETWORK_CONFIG_PATH=config/ci/anvil.json \
GOVERNANCE="$governance" \
PAUSER="$pauser" \
forge script script/EtherdocReceiverScript.s.sol:EtherdocReceiverScript \
  --rpc-url "$rpc_url" \
  --sender "$deployer"

ending_nonce="$(cast nonce --rpc-url "$rpc_url" "$deployer")"
if [[ "$ending_nonce" != "$starting_nonce" ]]; then
  printf 'Dry-run unexpectedly changed deployer nonce: %s -> %s\n' "$starting_nonce" "$ending_nonce" >&2
  exit 1
fi

echo "Sender and receiver deployment dry-runs passed without broadcasting transactions"
