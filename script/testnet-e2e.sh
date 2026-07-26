#!/usr/bin/env bash
set -euo pipefail

required_variables=(
  SOURCE_RPC_URL
  DESTINATION_RPC_URL
  E2E_ISSUER_PRIVATE_KEY
  E2E_OPERATOR_PRIVATE_KEY
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
issuer="$(cast wallet address "${E2E_ISSUER_PRIVATE_KEY}")"
operator="$(cast wallet address "${E2E_OPERATOR_PRIVATE_KEY}")"
readonly verify_signature='verifyDocument(bytes32,bytes32)((bytes32,bytes32,bytes32,string,uint8,bytes32,address,uint256,uint64,uint64,uint64,uint16,uint8,bytes32,bytes32),bool,bool)'

read -r content_digest document_cid replacement_digest replacement_cid < <(
  python3 - "${GITHUB_RUN_ID:-local}" "${started_at}" <<'PY'
import base64
import hashlib
import sys

def canonical_payload(label):
    payload = f"etherdoc-testnet-e2e:{sys.argv[1]}:{sys.argv[2]}:{label}".encode()
    digest = hashlib.sha256(payload).digest()
    cid_bytes = bytes((0x01, 0x55, 0x12, 0x20)) + digest
    cid = "b" + base64.b32encode(cid_bytes).decode().lower().rstrip("=")
    return f"0x{digest.hex()}", cid

original = canonical_payload("original")
replacement = canonical_payload("replacement")
print(*original, *replacement)
PY
)

issuer_authorized="$(
  cast call "${ETHERDOC_SENDER}" \
    "isIssuerAuthorized(address)(bool)" "${issuer}" \
    --rpc-url "${SOURCE_RPC_URL}" --json | jq -r '.[0]'
)"
operator_role="$(
  cast call "${ETHERDOC_SENDER}" "OPERATOR_ROLE()(bytes32)" \
    --rpc-url "${SOURCE_RPC_URL}" --json | jq -r '.[0]'
)"
operator_authorized="$(
  cast call "${ETHERDOC_SENDER}" \
    "hasRole(bytes32,address)(bool)" "${operator_role}" "${operator}" \
    --rpc-url "${SOURCE_RPC_URL}" --json | jq -r '.[0]'
)"
remote_trusted="$(
  cast call "${ETHERDOC_RECEIVER}" \
    "isTrustedRemote(uint64,address)(bool)" "${SOURCE_CHAIN_SELECTOR}" "${ETHERDOC_SENDER}" \
    --rpc-url "${DESTINATION_RPC_URL}" --json | jq -r '.[0]'
)"

if [[ "${issuer_authorized}" != "true" || "${operator_authorized}" != "true" ]]; then
  echo "E2E issuer ${issuer} must be authorized and operator ${operator} must hold OPERATOR_ROLE" >&2
  exit 1
fi
if [[ "${issuer,,}" == "${operator,,}" ]]; then
  echo "E2E issuer and operator must be distinct accounts" >&2
  exit 1
fi
if [[ "${remote_trusted}" != "true" ]]; then
  echo "Destination does not trust the configured source selector/sender pair" >&2
  exit 1
fi

document_id="$(
  cast call "${ETHERDOC_SENDER}" \
    "computeDocumentId(address,bytes32)(bytes32)" "${issuer}" "${content_digest}" \
    --rpc-url "${SOURCE_RPC_URL}" --json | jq -r '.[0]'
)"
replacement_id="$(
  cast call "${ETHERDOC_SENDER}" \
    "computeDocumentId(address,bytes32)(bytes32)" "${issuer}" "${replacement_digest}" \
    --rpc-url "${SOURCE_RPC_URL}" --json | jq -r '.[0]'
)"

registration_receipt="$(
  cast send "${ETHERDOC_SENDER}" \
    "registerDocument(bytes32,string)" "${content_digest}" "${document_cid}" \
    --private-key "${E2E_ISSUER_PRIVATE_KEY}" --rpc-url "${SOURCE_RPC_URL}" \
    --confirmations 1 --timeout 180 --json
)"
registration_tx="$(jq -r '.transactionHash' <<<"${registration_receipt}")"

assert_verification() {
  local contract="$1"
  local rpc_url="$2"
  local expected_document_id="$3"
  local expected_digest="$4"
  local expected_active="$5"
  local label="$6"
  local verification
  local integrity_matches
  local is_active

  verification="$(
    cast call "${contract}" "${verify_signature}" \
      "${expected_document_id}" "${expected_digest}" --rpc-url "${rpc_url}" --json
  )"
  integrity_matches="$(jq -r '.[1]' <<<"${verification}")"
  is_active="$(jq -r '.[2]' <<<"${verification}")"
  if [[ "${integrity_matches}" != "true" || "${is_active}" != "${expected_active}" ]]; then
    printf '%s verification mismatch: integrity=%s active=%s\n' \
      "${label}" "${integrity_matches}" "${is_active}" >&2
    exit 1
  fi
}

dispatch_document() {
  local target_document_id="$1"
  local quoted_fee
  local maximum_fee
  local dispatch_receipt
  local dispatch_tx
  local message_id

  quoted_fee="$(
    cast call "${ETHERDOC_SENDER}" \
      "quoteFee(bytes32,uint64)(uint256)" "${target_document_id}" "${DESTINATION_CHAIN_SELECTOR}" \
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
      "${target_document_id}" "${DESTINATION_CHAIN_SELECTOR}" "${maximum_fee}" \
      --private-key "${E2E_OPERATOR_PRIVATE_KEY}" --rpc-url "${SOURCE_RPC_URL}" \
      --confirmations 1 --timeout 180 --json
  )"
  dispatch_tx="$(jq -r '.transactionHash' <<<"${dispatch_receipt}")"
  message_id="$(
    jq -r --arg topic "${message_event_topic}" \
      '.logs[] | select((.topics[0] | ascii_downcase) == ($topic | ascii_downcase)) | .topics[1]' \
      <<<"${dispatch_receipt}" | head -n 1
  )"

  if [[ -z "${message_id}" || "${message_id}" == "null" ]]; then
    echo "MessageSent event was not found in dispatch transaction ${dispatch_tx}" >&2
    exit 1
  fi
  printf '%s %s\n' "${dispatch_tx}" "${message_id}"
}

wait_for_message() {
  local message_id="$1"
  local expected_document_id="$2"
  local processed
  local processed_json
  local received_document_id
  local now

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
      if [[ "${received_document_id,,}" != "${expected_document_id,,}" ]]; then
        echo "Received message resolves to unexpected document ${received_document_id}" >&2
        exit 1
      fi
      echo "Destination processed ${message_id} for ${expected_document_id}"
      return
    fi

    now="$(date +%s)"
    if (( now - started_at >= timeout_seconds )); then
      echo "Timed out waiting for destination receipt for ${message_id}" >&2
      exit 1
    fi
    sleep "${poll_seconds}"
  done
}

message_event_topic="$(
  cast keccak "MessageSent(bytes32,bytes32,uint64,address,string,uint64,uint8,uint32,address,uint256)"
)"

assert_verification "${ETHERDOC_SENDER}" "${SOURCE_RPC_URL}" \
  "${document_id}" "${content_digest}" true "source registered document"
read -r active_dispatch_tx active_message_id < <(dispatch_document "${document_id}")
echo "Registered document ${document_id} in ${registration_tx}"
echo "Dispatched active version in ${active_dispatch_tx} as ${active_message_id}"
wait_for_message "${active_message_id}" "${document_id}"
assert_verification "${ETHERDOC_RECEIVER}" "${DESTINATION_RPC_URL}" \
  "${document_id}" "${content_digest}" true "destination registered document"

supersession_receipt="$(
  cast send "${ETHERDOC_SENDER}" \
    "supersedeDocument(bytes32,bytes32,string,bytes32)" \
    "${document_id}" "${replacement_digest}" "${replacement_cid}" \
    "0x0000000000000000000000000000000000000000000000000000000000000000" \
    --private-key "${E2E_ISSUER_PRIVATE_KEY}" --rpc-url "${SOURCE_RPC_URL}" \
    --confirmations 1 --timeout 180 --json
)"
supersession_tx="$(jq -r '.transactionHash' <<<"${supersession_receipt}")"
assert_verification "${ETHERDOC_SENDER}" "${SOURCE_RPC_URL}" \
  "${document_id}" "${content_digest}" false "source superseded document"
assert_verification "${ETHERDOC_SENDER}" "${SOURCE_RPC_URL}" \
  "${replacement_id}" "${replacement_digest}" true "source replacement document"

read -r superseded_dispatch_tx superseded_message_id < <(dispatch_document "${document_id}")
echo "Superseded ${document_id} with ${replacement_id} in ${supersession_tx}"
echo "Dispatched superseded version in ${superseded_dispatch_tx} as ${superseded_message_id}"
wait_for_message "${superseded_message_id}" "${document_id}"
assert_verification "${ETHERDOC_RECEIVER}" "${DESTINATION_RPC_URL}" \
  "${document_id}" "${content_digest}" false "destination superseded document"

read -r replacement_dispatch_tx replacement_message_id < <(dispatch_document "${replacement_id}")
echo "Dispatched replacement in ${replacement_dispatch_tx} as ${replacement_message_id}"
wait_for_message "${replacement_message_id}" "${replacement_id}"
assert_verification "${ETHERDOC_RECEIVER}" "${DESTINATION_RPC_URL}" \
  "${replacement_id}" "${replacement_digest}" true "destination replacement document"

revocation_receipt="$(
  cast send "${ETHERDOC_SENDER}" \
    "revokeDocument(bytes32)" "${replacement_id}" \
    --private-key "${E2E_ISSUER_PRIVATE_KEY}" --rpc-url "${SOURCE_RPC_URL}" \
    --confirmations 1 --timeout 180 --json
)"
revocation_tx="$(jq -r '.transactionHash' <<<"${revocation_receipt}")"
assert_verification "${ETHERDOC_SENDER}" "${SOURCE_RPC_URL}" \
  "${replacement_id}" "${replacement_digest}" false "source revoked replacement"

read -r revoked_dispatch_tx revoked_message_id < <(dispatch_document "${replacement_id}")
echo "Revoked replacement in ${revocation_tx}"
echo "Dispatched revoked version in ${revoked_dispatch_tx} as ${revoked_message_id}"
wait_for_message "${revoked_message_id}" "${replacement_id}"
assert_verification "${ETHERDOC_RECEIVER}" "${DESTINATION_RPC_URL}" \
  "${replacement_id}" "${replacement_digest}" false "destination revoked replacement"

echo "Testnet lifecycle E2E passed for ${document_id} and replacement ${replacement_id}"
