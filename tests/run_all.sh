#!/usr/bin/env bash
# AgentBridge — full test suite runner.
# Exits nonzero on any failure. Prints summary table.

set -u
cd "$(dirname "$0")"

tests=(
  test_delivery.sh
  test_contention.sh
  test_crash.sh
  test_transcript.sh
  test_security.sh
  test_ux.sh
)

if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_BAD=$'\e[31m'; C_HEAD=$'\e[1;36m'; C_RST=$'\e[0m'
else
  C_OK=""; C_BAD=""; C_HEAD=""; C_RST=""
fi

declare -A status
declare -A duration
failed=0

for t in "${tests[@]}"; do
  echo "${C_HEAD}== running $t ==${C_RST}"
  start=$(date +%s.%N)
  if "./$t"; then
    status[$t]="${C_OK}PASS${C_RST}"
  else
    status[$t]="${C_BAD}FAIL${C_RST}"
    failed=$((failed + 1))
  fi
  end=$(date +%s.%N)
  duration[$t]=$(python3 -c "print(f'{$end-$start:.2f}s')")
  echo
done

echo "${C_HEAD}== Summary ==${C_RST}"
for t in "${tests[@]}"; do
  printf "  %-25s  %b  %s\n" "$t" "${status[$t]}" "${duration[$t]}"
done

if [[ $failed -eq 0 ]]; then
  echo "${C_OK}ALL TESTS PASSED${C_RST}"
  exit 0
else
  echo "${C_BAD}$failed test(s) FAILED${C_RST}"
  exit 1
fi
