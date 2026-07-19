#!/usr/bin/env bash
set -euo pipefail

readonly GAS_TEST_PATTERN='test_(registersCanonicalDocumentOnce|quoteFeeAndMaximumProtectAgainstFeeIncrease|sendAndReceiveCrossChainMessagePayFeesInLink)'
tolerance="${GAS_SNAPSHOT_TOLERANCE:-5}"

if [[ ! "$tolerance" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "GAS_SNAPSHOT_TOLERANCE must be a non-negative percentage" >&2
  exit 2
fi

forge snapshot \
  --match-test "$GAS_TEST_PATTERN" \
  --check .gas-snapshot \
  --tolerance "$tolerance"
