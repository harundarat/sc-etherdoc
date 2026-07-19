#!/usr/bin/env bash
set -euo pipefail

readonly port="${ANVIL_PORT:-8545}"
readonly rpc_url="http://127.0.0.1:${port}"
readonly deployer="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
readonly treasury="0x1000000000000000000000000000000000000001"
readonly target_link_balance="100000000000000000000"
readonly retained_link_balance="40000000000000000000"
readonly expected_treasury_balance="60000000000000000000"
readonly work_dir="deployments/ci-workflow-${port}-$$"
readonly deployment_dir="${work_dir}/addresses"
readonly network_config_path="${work_dir}/networks.json"

anvil --host 127.0.0.1 --port "$port" --chain-id 31337 --silent >"${TMPDIR:-/tmp}/etherdoc-workflow-anvil.log" 2>&1 &
anvil_pid=$!
cleanup() {
  kill "$anvil_pid" 2>/dev/null || true
  wait "$anvil_pid" 2>/dev/null || true
  rm -rf "$work_dir"
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

mkdir -p "$deployment_dir"
router_deployment="$(
  forge create test/mocks/MockRouter.sol:MockRouter \
    --rpc-url "$rpc_url" --broadcast --unlocked --from "$deployer" --json
)"
link_deployment="$(
  forge create test/mocks/MockLinkToken.sol:MockLinkToken \
    --rpc-url "$rpc_url" --broadcast --unlocked --from "$deployer" --json
)"
router="$(jq -r '.deployedTo' <<<"$router_deployment")"
link_token="$(jq -r '.deployedTo' <<<"$link_deployment")"
if [[ -z "$router" || "$router" == "null" || -z "$link_token" || "$link_token" == "null" ]]; then
  echo "Failed to deploy local Router or LINK token" >&2
  exit 1
fi

jq \
  --arg router "$router" \
  --arg link "$link_token" \
  --arg rpc "$rpc_url" \
  '(.networks[].router) = $router
    | (.networks[].linkToken) = $link
    | (.networks[].explorer) = $rpc
    | (.networks[].rpcAlias) = $rpc' \
  config/ci/anvil-workflow.json >"$network_config_path"

common_environment=(
  "ALLOW_DIRTY_DEPLOYMENT=${ALLOW_DIRTY_DEPLOYMENT:-0}"
  "RPC_URL=$rpc_url"
  "NETWORK_CONFIG_PATH=$network_config_path"
  "DEPLOYMENT_DIR=$deployment_dir"
  "GOVERNANCE=$deployer"
  "INITIAL_ISSUER=$deployer"
  "OPERATOR=$deployer"
  "PAUSER=$deployer"
)
wallet_options=(--unlocked --sender "$deployer")

env "${common_environment[@]}" NETWORK=localDestination \
  bash script/deploy-contract.sh receiver "${wallet_options[@]}"
env "${common_environment[@]}" NETWORK=localSource \
  bash script/deploy-contract.sh sender "${wallet_options[@]}"

for role_and_network in "receiver localDestination" "sender localSource"; do
  read -r role network <<<"$role_and_network"
  manifest="${deployment_dir}/manifests/${network}-${role}.json"
  jq -e '
    .schemaVersion == 1
      and (.chainId == 31337)
      and (.chainSelector | type == "string")
      and (.address | startswith("0x"))
      and (.transactionHash | startswith("0x"))
      and (.source.gitCommit | length == 40)
      and (.compiler.version | startswith("0.8.36+commit."))
      and (.constructorArgs.encoded | startswith("0x"))
      and (.timestamp > 0)
  ' "$manifest" >/dev/null
done

nonce_before_deploy_rerun="$(cast nonce --rpc-url "$rpc_url" "$deployer")"
env "${common_environment[@]}" NETWORK=localDestination \
  bash script/deploy-contract.sh receiver "${wallet_options[@]}"
env "${common_environment[@]}" NETWORK=localSource \
  bash script/deploy-contract.sh sender "${wallet_options[@]}"
nonce_after_deploy_rerun="$(cast nonce --rpc-url "$rpc_url" "$deployer")"
if [[ "$nonce_after_deploy_rerun" != "$nonce_before_deploy_rerun" ]]; then
  echo "Idempotent deployment rerun changed the deployer nonce" >&2
  exit 1
fi

configure_environment=(
  "NETWORK_CONFIG_PATH=$network_config_path"
  "DEPLOYMENT_DIR=$deployment_dir"
  "SOURCE_NETWORK=localSource"
  "DESTINATION_NETWORK=localDestination"
)
env "${configure_environment[@]}" CONFIGURE_TARGET=RECEIVER \
  forge script script/ConfigureEtherdocRemotes.s.sol:ConfigureEtherdocRemotesScript \
    --rpc-url "$rpc_url" --broadcast "${wallet_options[@]}"
env "${configure_environment[@]}" CONFIGURE_TARGET=SENDER \
  forge script script/ConfigureEtherdocRemotes.s.sol:ConfigureEtherdocRemotesScript \
    --rpc-url "$rpc_url" --broadcast "${wallet_options[@]}"

nonce_before_config_rerun="$(cast nonce --rpc-url "$rpc_url" "$deployer")"
env "${configure_environment[@]}" CONFIGURE_TARGET=RECEIVER \
  forge script script/ConfigureEtherdocRemotes.s.sol:ConfigureEtherdocRemotesScript \
    --rpc-url "$rpc_url" --broadcast "${wallet_options[@]}"
env "${configure_environment[@]}" CONFIGURE_TARGET=SENDER \
  forge script script/ConfigureEtherdocRemotes.s.sol:ConfigureEtherdocRemotesScript \
    --rpc-url "$rpc_url" --broadcast "${wallet_options[@]}"
nonce_after_config_rerun="$(cast nonce --rpc-url "$rpc_url" "$deployer")"
if [[ "$nonce_after_config_rerun" != "$nonce_before_config_rerun" ]]; then
  echo "Idempotent remote configuration rerun changed the deployer nonce" >&2
  exit 1
fi

treasury_environment=(
  "NETWORK=localSource"
  "NETWORK_CONFIG_PATH=$network_config_path"
  "DEPLOYMENT_DIR=$deployment_dir"
)
env "${treasury_environment[@]}" TREASURY_ACTION=FUND TARGET_LINK_BALANCE="$target_link_balance" \
  forge script script/ManageEtherdocTreasury.s.sol:ManageEtherdocTreasuryScript \
    --rpc-url "$rpc_url" --broadcast "${wallet_options[@]}"
nonce_before_fund_rerun="$(cast nonce --rpc-url "$rpc_url" "$deployer")"
env "${treasury_environment[@]}" TREASURY_ACTION=FUND TARGET_LINK_BALANCE="$target_link_balance" \
  forge script script/ManageEtherdocTreasury.s.sol:ManageEtherdocTreasuryScript \
    --rpc-url "$rpc_url" --broadcast "${wallet_options[@]}"
nonce_after_fund_rerun="$(cast nonce --rpc-url "$rpc_url" "$deployer")"
if [[ "$nonce_after_fund_rerun" != "$nonce_before_fund_rerun" ]]; then
  echo "Idempotent funding rerun changed the deployer nonce" >&2
  exit 1
fi

env "${treasury_environment[@]}" TREASURY_ACTION=WITHDRAW RETAIN_LINK_BALANCE="$retained_link_balance" \
  TREASURY="$treasury" \
  forge script script/ManageEtherdocTreasury.s.sol:ManageEtherdocTreasuryScript \
    --rpc-url "$rpc_url" --broadcast "${wallet_options[@]}"
nonce_before_withdraw_rerun="$(cast nonce --rpc-url "$rpc_url" "$deployer")"
env "${treasury_environment[@]}" TREASURY_ACTION=WITHDRAW RETAIN_LINK_BALANCE="$retained_link_balance" \
  TREASURY="$treasury" \
  forge script script/ManageEtherdocTreasury.s.sol:ManageEtherdocTreasuryScript \
    --rpc-url "$rpc_url" --broadcast "${wallet_options[@]}"
nonce_after_withdraw_rerun="$(cast nonce --rpc-url "$rpc_url" "$deployer")"
if [[ "$nonce_after_withdraw_rerun" != "$nonce_before_withdraw_rerun" ]]; then
  echo "Idempotent withdrawal rerun changed the deployer nonce" >&2
  exit 1
fi

sender="$(jq -r '.sender' "${deployment_dir}/localSource.json")"
sender_link_balance_raw="$(cast call --rpc-url "$rpc_url" "$link_token" "balanceOf(address)" "$sender")"
treasury_link_balance_raw="$(cast call --rpc-url "$rpc_url" "$link_token" "balanceOf(address)" "$treasury")"
sender_link_balance="$(cast to-dec "$sender_link_balance_raw")"
treasury_link_balance="$(cast to-dec "$treasury_link_balance_raw")"
if [[ "$sender_link_balance" != "$retained_link_balance" ]]; then
  printf 'Unexpected sender LINK balance: expected %s, got %s\n' "$retained_link_balance" "$sender_link_balance" >&2
  exit 1
fi
if [[ "$treasury_link_balance" != "$expected_treasury_balance" ]]; then
  printf 'Unexpected treasury LINK balance: expected %s, got %s\n' \
    "$expected_treasury_balance" "$treasury_link_balance" >&2
  exit 1
fi

verify_command="$(
  NETWORK=localSource RPC_URL="$rpc_url" DEPLOYMENT_DIR="$deployment_dir" VERIFY_DRY_RUN=1 \
    bash script/verify-contract.sh sender
)"
if [[ "$verify_command" != *"forge verify-contract"* || "$verify_command" != *"--constructor-args"* ]]; then
  echo "Verification command was not assembled from the deployment manifest" >&2
  exit 1
fi

echo "Idempotent deployment, configuration, treasury, manifest, and verification workflow passed"
