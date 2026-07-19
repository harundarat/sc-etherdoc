#!/usr/bin/env bash
set -euo pipefail

role="${1:-}"
if [[ "$role" != "sender" && "$role" != "receiver" ]]; then
  echo "Usage: $0 <sender|receiver>" >&2
  exit 2
fi

: "${NETWORK:?Set NETWORK to the deployed network name}"
: "${RPC_URL:?Set RPC_URL to the deployment RPC endpoint}"

readonly deployment_dir="${DEPLOYMENT_DIR:-deployments/testnet}"
readonly manifest_path="${deployment_dir}/manifests/${NETWORK}-${role}.json"
if [[ ! -f "$manifest_path" ]]; then
  echo "Deployment manifest is missing: $manifest_path" >&2
  exit 1
fi

address="$(jq -r '.address' "$manifest_path")"
artifact="$(jq -r '.artifact' "$manifest_path")"
chain_id="$(jq -r '.chainId' "$manifest_path")"
transaction_hash="$(jq -r '.transactionHash' "$manifest_path")"
constructor_args="$(jq -r '.constructorArgs.encoded' "$manifest_path")"
compiler_version="$(jq -r '.compiler.version' "$manifest_path")"
optimizer_runs="$(jq -r '.compiler.optimizer.runs' "$manifest_path")"
evm_version="$(jq -r '.compiler.evmVersion' "$manifest_path")"
verifier="${VERIFIER:-etherscan}"

rpc_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$rpc_chain_id" != "$chain_id" ]]; then
  printf 'RPC chain ID mismatch: manifest %s, RPC %s\n' "$chain_id" "$rpc_chain_id" >&2
  exit 1
fi
if [[ "$(cast code --rpc-url "$RPC_URL" "$address")" == "0x" ]]; then
  echo "No runtime bytecode found at manifest address $address" >&2
  exit 1
fi

command=(
  forge verify-contract
  "$address"
  "$artifact"
  --chain "$chain_id"
  --rpc-url "$RPC_URL"
  --verifier "$verifier"
  --constructor-args "$constructor_args"
  --creation-transaction-hash "$transaction_hash"
  --compiler-version "$compiler_version"
  --num-of-optimizations "$optimizer_runs"
  --evm-version "$evm_version"
  --watch
)
if [[ -n "${VERIFIER_URL:-}" ]]; then
  command+=(--verifier-url "$VERIFIER_URL")
fi
if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  command+=(--etherscan-api-key "$ETHERSCAN_API_KEY")
fi

if [[ "${VERIFY_DRY_RUN:-0}" == "1" ]]; then
  printf '%q ' "${command[@]}"
  printf '\n'
  exit 0
fi

"${command[@]}"
