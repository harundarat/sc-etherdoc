#!/usr/bin/env bash
set -euo pipefail

readonly EIP170_RUNTIME_LIMIT=24576
readonly EIP3860_INITCODE_LIMIT=49152
readonly SIZE_CONFIG="${SIZE_CONFIG:-config/ci/contract-sizes.json}"

# Lint-only artifacts can omit bytecode while still making an incremental build look current.
forge build --sizes --force

while IFS= read -r entry; do
  contract="$(jq -r '.contract' <<<"$entry")"
  artifact="$(jq -r '.artifact' <<<"$entry")"
  max_runtime="$(jq -r '.maxRuntimeBytes' <<<"$entry")"
  max_initcode="$(jq -r '.maxInitcodeBytes' <<<"$entry")"

  if [[ ! -f "$artifact" ]]; then
    printf 'Missing artifact for %s: %s\n' "$contract" "$artifact" >&2
    exit 1
  fi

  runtime_hex="$(jq -er '.deployedBytecode.object' "$artifact")"
  initcode_hex="$(jq -er '.bytecode.object' "$artifact")"
  if [[ "$runtime_hex" != 0x* || "$initcode_hex" != 0x* ]]; then
    printf 'Malformed bytecode in %s\n' "$artifact" >&2
    exit 1
  fi

  runtime_bytes=$(( (${#runtime_hex} - 2) / 2 ))
  initcode_bytes=$(( (${#initcode_hex} - 2) / 2 ))
  printf '%s: runtime %d/%d bytes; initcode %d/%d bytes\n' \
    "$contract" "$runtime_bytes" "$max_runtime" "$initcode_bytes" "$max_initcode"

  if (( max_runtime > EIP170_RUNTIME_LIMIT || max_initcode > EIP3860_INITCODE_LIMIT )); then
    printf 'Configured budget for %s exceeds an EVM protocol limit\n' "$contract" >&2
    exit 1
  fi
  if (( runtime_bytes > max_runtime )); then
    printf '%s runtime exceeds its reviewed budget by %d bytes\n' "$contract" "$((runtime_bytes - max_runtime))" >&2
    exit 1
  fi
  if (( initcode_bytes > max_initcode )); then
    printf '%s initcode exceeds its reviewed budget by %d bytes\n' "$contract" "$((initcode_bytes - max_initcode))" >&2
    exit 1
  fi
done < <(jq -c '.[]' "$SIZE_CONFIG")
