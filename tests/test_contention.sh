#!/usr/bin/env bash
# Phase 5.2 — concurrent same-file edit lock blocking.
# 8 parallel acquire attempts → exactly 1 succeeds, 7 fail.
# Release → reacquire works. Stale via ttl=1 → reap succeeds.
# Emergency override w/o warning → rejected; with warning → accepted.

set -euo pipefail
TEST_NAME="test_contention"
source "$(dirname "$0")/_lib.sh"

setup_workdir

target="apps/api-rs/src/http/admin_audit.rs"
P=8
results_dir="$WORKDIR/results"
mkdir -p "$results_dir"

# Launch P parallel acquires (alternate claude/codex).
for i in $(seq 1 $P); do
  if (( i % 2 == 0 )); then a=claude; else a=codex; fi
  (
    if out=$("$AB" lock acquire --as $a --path "$target" --ttl 30 \
              --session eng-conflict --reason "race-$i" 2>"$results_dir/$i.err"); then
      echo "OK $a $out" > "$results_dir/$i.out"
    else
      echo "FAIL $a" > "$results_dir/$i.out"
    fi
  ) &
done
wait

ok_count=$(cat "$results_dir"/*.out | grep -c '^OK ' || true)
fail_count=$(cat "$results_dir"/*.out | grep -c '^FAIL' || true)
assert_eq "$ok_count" "1" "exactly 1 acquire succeeded out of $P"
assert_eq "$fail_count" "$((P-1))" "remaining $((P-1)) acquires rejected"

winner_line=$(cat "$results_dir"/*.out | grep '^OK ' | head -1)
winner_agent=$(echo "$winner_line" | awk '{print $2}')
lock_id=$(echo "$winner_line" | awk '{print $3}')
[[ -n "$winner_agent" && -n "$lock_id" ]] && pass "winner identified ($winner_agent / $lock_id)" \
  || fail "winner parse"

# Release by winner, then other agent acquires.
"$AB" lock release --as "$winner_agent" --path "$target" --session eng-conflict >/dev/null
other=$([[ $winner_agent == claude ]] && echo codex || echo claude)
"$AB" lock acquire --as "$other" --path "$target" --ttl 30 --session eng-conflict >/dev/null \
  && pass "other agent acquires after release" \
  || fail "post-release acquire by $other"
"$AB" lock release --as "$other" --path "$target" --session eng-conflict >/dev/null

# Stale: ttl=1, sleep 2, reap.
"$AB" lock acquire --as claude --path "$target" --ttl 1 --session eng-conflict >/dev/null
sleep 2
"$AB" lock reap --as codex --path "$target" --session eng-conflict >/dev/null \
  && pass "stale lock reaped" \
  || fail "stale reap failed"

# Override guardrail: claude acquires non-stale, codex tries to reap → must fail.
"$AB" lock acquire --as claude --path "$target" --ttl 300 --session eng-conflict >/dev/null
if "$AB" lock reap --as codex --path "$target" --session eng-conflict --force-stale 2>/dev/null; then
  fail "override without warning msg was accepted"
else
  pass "override without warning msg rejected"
fi

# Send warning msg w/ correct tag, then override succeeds.
"$AB" send --from codex --to claude --type warning \
  --subject "emergency override" --body "claude crashed; reaping lock" \
  --session eng-conflict --tag "override:apps__api-rs__src__http__admin_audit.rs" >/dev/null
"$AB" lock reap --as codex --path "$target" --session eng-conflict --force-stale >/dev/null \
  && pass "override accepted with warning msg" \
  || fail "override rejected despite warning msg"

# override_recorded event present.
if grep -q '"event":"override_recorded"' .agent-bus/events.jsonl; then
  pass "override_recorded event logged"
else
  fail "no override_recorded event"
fi

finish
