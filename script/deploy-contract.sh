#!/usr/bin/env bash
set -euo pipefail

role="${1:-}"
if [[ "$role" != "sender" && "$role" != "receiver" ]]; then
  echo "Usage: $0 <sender|receiver> [forge script wallet options]" >&2
  exit 2
fi
shift

: "${NETWORK:?Set NETWORK to a key in the network config}"
: "${RPC_URL:?Set RPC_URL to the deployment RPC endpoint}"

readonly network_config_path="${NETWORK_CONFIG_PATH:-config/networks/testnet.json}"
readonly deployment_dir="${DEPLOYMENT_DIR:-deployments/testnet}"
readonly deployment_path="${deployment_dir}/${NETWORK}.json"
readonly manifest_dir="${deployment_dir}/manifests"
readonly manifest_path="${manifest_dir}/${NETWORK}-${role}.json"

for command in cast forge git jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is missing: $command" >&2
    exit 1
  fi
done

if ! jq -e --arg network "$NETWORK" '.networks[$network]' "$network_config_path" >/dev/null; then
  echo "Network '$NETWORK' is absent from $network_config_path" >&2
  exit 1
fi

chain_id="$(jq -r --arg network "$NETWORK" '.networks[$network].chainId' "$network_config_path")"
chain_selector="$(jq -r --arg network "$NETWORK" '.networks[$network].chainSelector' "$network_config_path")"
rpc_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$rpc_chain_id" != "$chain_id" ]]; then
  printf 'RPC chain ID mismatch for %s: expected %s, got %s\n' "$NETWORK" "$chain_id" "$rpc_chain_id" >&2
  exit 1
fi

git_dirty=false
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  git_dirty=true
  if [[ "${ALLOW_DIRTY_DEPLOYMENT:-0}" != "1" ]]; then
    echo "Refusing to deploy from a dirty worktree; commit the exact source first" >&2
    exit 1
  fi
fi

case "$role" in
  sender)
    script_file="EtherdocSenderScript.s.sol"
    script_contract="EtherdocSenderScript"
    contract_name="EtherdocSender"
    artifact="src/EtherdocSender.sol:EtherdocSender"
    ;;
  receiver)
    script_file="EtherdocReceiverScript.s.sol"
    script_contract="EtherdocReceiverScript"
    contract_name="EtherdocReceiver"
    artifact="src/EtherdocReceiver.sol:EtherdocReceiver"
    ;;
esac

existing_address=""
if [[ -f "$deployment_path" ]]; then
  existing_address="$(jq -r --arg role "$role" '.[$role] // empty' "$deployment_path")"
fi

NETWORK_CONFIG_PATH="$network_config_path" \
DEPLOYMENT_DIR="$deployment_dir" \
NETWORK="$NETWORK" \
  forge script "script/${script_file}:${script_contract}" \
    --rpc-url "$RPC_URL" \
    --broadcast \
    "$@"

if [[ ! -f "$deployment_path" ]]; then
  echo "Deployment script did not create $deployment_path" >&2
  exit 1
fi
address="$(jq -r --arg role "$role" '.[$role] // empty' "$deployment_path")"
if [[ -z "$address" || "$address" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "Deployment address is missing for role '$role' in $deployment_path" >&2
  exit 1
fi
code="$(cast code --rpc-url "$RPC_URL" "$address")"
if [[ "$code" == "0x" ]]; then
  echo "No runtime bytecode found at $address" >&2
  exit 1
fi

if [[ -n "$existing_address" && "${existing_address,,}" == "${address,,}" ]]; then
  if [[ ! -f "$manifest_path" ]]; then
    echo "Existing deployment has no manifest at $manifest_path; refusing an unverifiable backfill" >&2
    exit 1
  fi
  manifest_address="$(jq -r '.address' "$manifest_path")"
  manifest_chain_id="$(jq -r '.chainId' "$manifest_path")"
  if [[ "${manifest_address,,}" != "${address,,}" || "$manifest_chain_id" != "$chain_id" ]]; then
    echo "Existing manifest does not match the on-chain deployment" >&2
    exit 1
  fi
  echo "$contract_name is already deployed at $address; manifest preserved at $manifest_path"
  exit 0
fi

readonly broadcast_path="broadcast/${script_file}/${chain_id}/run-latest.json"
if [[ ! -f "$broadcast_path" ]]; then
  echo "Foundry broadcast artifact is missing: $broadcast_path" >&2
  exit 1
fi

deployment_tx="$(
  jq -c --arg contract "$contract_name" \
    '[.transactions[] | select(.transactionType == "CREATE" and .contractName == $contract)] | last // empty' \
    "$broadcast_path"
)"
if [[ -z "$deployment_tx" ]]; then
  echo "No $contract_name creation transaction found in $broadcast_path" >&2
  exit 1
fi

tx_hash="$(jq -r '.hash // empty' <<<"$deployment_tx")"
tx_address="$(jq -r '.contractAddress // empty' <<<"$deployment_tx")"
if [[ -z "$tx_hash" || "${tx_address,,}" != "${address,,}" ]]; then
  echo "Broadcast transaction does not reconcile with the saved deployment address" >&2
  exit 1
fi

receipt="$(cast receipt --rpc-url "$RPC_URL" "$tx_hash" --json)"
block_number_raw="$(jq -r '.blockNumber' <<<"$receipt")"
if [[ "$block_number_raw" == 0x* ]]; then
  block_number="$(cast to-dec "$block_number_raw")"
else
  block_number="$block_number_raw"
fi
block="$(cast block --rpc-url "$RPC_URL" "$block_number" --json)"
block_timestamp_raw="$(jq -r '.timestamp' <<<"$block")"
if [[ "$block_timestamp_raw" == 0x* ]]; then
  block_timestamp="$(cast to-dec "$block_timestamp_raw")"
else
  block_timestamp="$block_timestamp_raw"
fi

metadata="$(forge inspect "$artifact" metadata)"
compiler_version="$(jq -r '.compiler.version' <<<"$metadata")"
optimizer_enabled="$(jq -r '.settings.optimizer.enabled' <<<"$metadata")"
optimizer_runs="$(jq -r '.settings.optimizer.runs' <<<"$metadata")"
evm_version="$(jq -r '.settings.evmVersion' <<<"$metadata")"
creation_input="$(jq -r '.transaction.input' <<<"$deployment_tx")"
creation_bytecode="$(forge inspect "$artifact" bytecode)"
if [[ "${creation_input:0:${#creation_bytecode}}" != "$creation_bytecode" ]]; then
  echo "Creation transaction bytecode does not match the current artifact" >&2
  exit 1
fi
constructor_args_encoded="0x${creation_input:${#creation_bytecode}}"
constructor_args="$(jq -c '.arguments' <<<"$deployment_tx")"
deployer="$(jq -r '.transaction.from' <<<"$deployment_tx")"
code_hash="$(cast keccak "$code")"
git_commit="$(git rev-parse HEAD)"
generated_at="$(date +%s)"

mkdir -p "$manifest_dir"
jq -n \
  --arg network "$NETWORK" \
  --arg role "$role" \
  --arg contract_name "$contract_name" \
  --arg artifact "$artifact" \
  --arg address "$address" \
  --arg chain_selector "$chain_selector" \
  --arg transaction_hash "$tx_hash" \
  --arg deployer "$deployer" \
  --arg code_hash "$code_hash" \
  --arg git_commit "$git_commit" \
  --arg compiler_version "$compiler_version" \
  --arg evm_version "$evm_version" \
  --arg constructor_args_encoded "$constructor_args_encoded" \
  --argjson chain_id "$chain_id" \
  --argjson block_number "$block_number" \
  --argjson timestamp "$block_timestamp" \
  --argjson generated_at "$generated_at" \
  --argjson optimizer_enabled "$optimizer_enabled" \
  --argjson optimizer_runs "$optimizer_runs" \
  --argjson constructor_args "$constructor_args" \
  --argjson git_dirty "$git_dirty" \
  '{
    schemaVersion: 1,
    network: $network,
    role: $role,
    contractName: $contract_name,
    artifact: $artifact,
    address: $address,
    chainId: $chain_id,
    chainSelector: $chain_selector,
    transactionHash: $transaction_hash,
    blockNumber: $block_number,
    timestamp: $timestamp,
    deployer: $deployer,
    runtimeCodeHash: $code_hash,
    source: {
      gitCommit: $git_commit,
      gitDirty: $git_dirty
    },
    compiler: {
      version: $compiler_version,
      evmVersion: $evm_version,
      optimizer: {
        enabled: $optimizer_enabled,
        runs: $optimizer_runs
      }
    },
    constructorArgs: {
      values: $constructor_args,
      encoded: $constructor_args_encoded
    },
    manifestGeneratedAt: $generated_at
  }' >"$manifest_path"

echo "$contract_name deployed at $address"
echo "Deployment manifest written to $manifest_path"
