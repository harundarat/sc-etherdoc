#!/usr/bin/env bash
set -euo pipefail

threshold="${COVERAGE_THRESHOLD:-100}"
if [[ ! "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v value="$threshold" 'BEGIN { exit !(value >= 0 && value <= 100) }'; then
  echo "COVERAGE_THRESHOLD must be a number between 0 and 100" >&2
  exit 2
fi

if ! coverage_output="$(
  forge coverage \
    --report summary \
    --no-match-test 'invariant_' \
    --no-match-coverage '(script|test|lib)' 2>&1
)"; then
  printf '%s\n' "$coverage_output"
  exit 1
fi
printf '%s\n' "$coverage_output"

total_line="$(awk '/^\| Total[[:space:]]+\|/ { print; exit }' <<<"$coverage_output")"
mapfile -t percentages < <(grep -oE '[0-9]+([.][0-9]+)?%' <<<"$total_line" | tr -d '%')
metrics=(lines statements branches functions)

if [[ "${#percentages[@]}" -ne "${#metrics[@]}" ]]; then
  echo "Unable to parse Forge coverage totals" >&2
  exit 1
fi

for index in "${!metrics[@]}"; do
  actual="${percentages[$index]}"
  if ! awk -v actual="$actual" -v minimum="$threshold" 'BEGIN { exit !(actual >= minimum) }'; then
    printf '%s coverage %s%% is below the required %s%%\n' "${metrics[$index]}" "$actual" "$threshold" >&2
    exit 1
  fi
done

printf 'Coverage gate passed: all metrics are at least %s%%\n' "$threshold"
