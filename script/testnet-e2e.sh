#!/usr/bin/env bash
set -euo pipefail

required_variables=(
  SOURCE_RPC_URL
  DESTINATION_RPC_URL
  E2E_PRIVATE_KEY
  ETHERDOC_SENDER
  ETHERDOC_RECEIVER
  SOURCE_CHAIN_SELECTOR
  DESTINATION_CHAIN_SELECTOR
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Missing required environment variable: ${variable}" >&2
    exit 1
  fi
done

timeout_seconds="${E2E_TIMEOUT_SECONDS:-2700}"
poll_seconds="${E2E_POLL_SECONDS:-30}"
started_at="$(date +%s)"
account="$(cast wallet address "${E2E_PRIVATE_KEY}")"

read -r content_digest document_cid < <(
  python3 - "${GITHUB_RUN_ID:-local}" "${started_at}" <<'PY'
import base64
import hashlib
import sys

payload = f"etherdoc-testnet-e2e:{sys.argv[1]}:{sys.argv[2]}".encode()
digest = hashlib.sha256(payload).digest()
cid_bytes = bytes((0x01, 0x55, 0x12, 0x20)) + digest
cid = "b" + base64.b32encode(cid_bytes).decode().lower().rstrip("=")
print(f"0x{digest.hex()} {cid}")
PY
)

issuer_authorized="$(
  cast call "${ETHERDOC_SENDER}" \
    "isIssuerAuthorized(address)(bool)" "${account}" \
    --rpc-url "${SOURCE_RPC_URL}" --json | jq -r '.[0]'
)"
operator_role="$(
  cast call "${ETHERDOC_SENDER}" "OPERATOR_ROLE()(bytes32)" \
    --rpc-url "${SOURCE_RPC_URL}" --json | jq -r '.[0]'
)"
operator_authorized="$(
  cast call "${ETHERDOC_SENDER}" \
    "hasRole(bytes32,address)(bool)" "${operator_role}" "${account}" \
    --rpc-url "${SOURCE_RPC_URL}" --json | jq -r '.[0]'
)"
remote_trusted="$(
  cast call "${ETHERDOC_RECEIVER}" \
    "isTrustedRemote(uint64,address)(bool)" "${SOURCE_CHAIN_SELECTOR}" "${ETHERDOC_SENDER}" \
    --rpc-url "${DESTINATION_RPC_URL}" --json | jq -r '.[0]'
)"

if [[ "${issuer_authorized}" != "true" || "${operator_authorized}" != "true" ]]; then
  echo "E2E account ${account} must be an authorized issuer and operator" >&2
  exit 1
fi
if [[ "${remote_trusted}" != "true" ]]; then
  echo "Destination does not trust the configured source selector/sender pair" >&2
  exit 1
fi

document_id="$(
  cast call "${ETHERDOC_SENDER}" \
    "computeDocumentId(address,bytes32)(bytes32)" "${account}" "${content_digest}" \
    --rpc-url "${SOURCE_RPC_URL}" --json | jq -r '.[0]'
)"

registration_receipt="$(
  cast send "${ETHERDOC_SENDER}" \
    "registerDocument(bytes32,string)" "${content_digest}" "${document_cid}" \
    --private-key "${E2E_PRIVATE_KEY}" --rpc-url "${SOURCE_RPC_URL}" \
    --confirmations 1 --timeout 180 --json
)"
registration_tx="$(jq -r '.transactionHash' <<<"${registration_receipt}")"

quoted_fee="$(
  cast call "${ETHERDOC_SENDER}" \
    "quoteFee(bytes32,uint64)(uint256)" "${document_id}" "${DESTINATION_CHAIN_SELECTOR}" \
    --rpc-url "${SOURCE_RPC_URL}" --json | jq -r '.[0] | tostring'
)"
maximum_fee="$(
  python3 - "${quoted_fee}" <<'PY'
import sys

fee = int(sys.argv[1])
print(fee + max(fee // 4, 1))
PY
)"

dispatch_receipt="$(
  cast send "${ETHERDOC_SENDER}" \
    "dispatchDocument(bytes32,uint64,uint256)" \
    "${document_id}" "${DESTINATION_CHAIN_SELECTOR}" "${maximum_fee}" \
    --private-key "${E2E_PRIVATE_KEY}" --rpc-url "${SOURCE_RPC_URL}" \
    --confirmations 1 --timeout 180 --json
)"
dispatch_tx="$(jq -r '.transactionHash' <<<"${dispatch_receipt}")"
message_event_topic="$(
  cast keccak "MessageSent(bytes32,bytes32,uint64,address,string,uint64,uint8,uint32,address,uint256)"
)"
message_id="$(
  jq -r --arg topic "${message_event_topic}" \
    '.logs[] | select((.topics[0] | ascii_downcase) == ($topic | ascii_downcase)) | .topics[1]' \
    <<<"${dispatch_receipt}" | head -n 1
)"

if [[ -z "${message_id}" || "${message_id}" == "null" ]]; then
  echo "MessageSent event was not found in dispatch transaction ${dispatch_tx}" >&2
  exit 1
fi

echo "Registered document ${document_id} in ${registration_tx}"
echo "Dispatched CCIP message ${message_id} in ${dispatch_tx}"

while true; do
  processed="false"
  if processed_json="$(
    cast call "${ETHERDOC_RECEIVER}" \
      "isMessageProcessed(bytes32)(bool)" "${message_id}" \
      --rpc-url "${DESTINATION_RPC_URL}" --json 2>/dev/null
  )"; then
    processed="$(jq -r '.[0]' <<<"${processed_json}")"
  fi

  if [[ "${processed}" == "true" ]]; then
    received_document_id="$(
      cast call "${ETHERDOC_RECEIVER}" \
        "getMessageDocument(bytes32)(bytes32)" "${message_id}" \
        --rpc-url "${DESTINATION_RPC_URL}" --json | jq -r '.[0]'
    )"
    if [[ "${received_document_id,,}" != "${document_id,,}" ]]; then
      echo "Received message resolves to unexpected document ${received_document_id}" >&2
      exit 1
    fi
    echo "Destination processed ${message_id} for ${document_id}"
    exit 0
  fi

  now="$(date +%s)"
  if (( now - started_at >= timeout_seconds )); then
    echo "Timed out waiting for destination receipt for ${message_id}" >&2
    exit 1
  fi
  sleep "${poll_seconds}"
done
