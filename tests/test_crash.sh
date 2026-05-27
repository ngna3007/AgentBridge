#!/usr/bin/env bash
# Phase 5.3 — crash/restart reliability with cursor persistence.
# Start watcher, send 2 msgs, kill -9 watcher mid-stream, send 3 more,
# restart watcher, verify total of 5 delivered exactly once in order.
# Also verify corrupt JSONL line skipped + warning event emitted.

set -euo pipefail
TEST_NAME="test_crash"
source "$(dirname "$0")/_lib.sh"

setup_workdir

session="eng-crash"
watch_log="$WORKDIR/watch.out"

start_watcher() {
  "$AB" watch --as codex --session "$session" --interval 100 \
        >> "$watch_log" 2>>"$WORKDIR/watch.err" &
  echo $!
}

# Phase A: send 2, watcher running.
pid=$(start_watcher)
sleep 0.2
"$AB" send --from claude --to codex --type task --subject "A1" --body "first" --session $session >/dev/null
"$AB" send --from claude --to codex --type task --subject "A2" --body "second" --session $session >/dev/null
sleep 0.4
kill -9 "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

phase_a_count=$(wc -l < "$watch_log" | tr -d ' ')
assert_eq "$phase_a_count" "2" "watcher drained 2 msgs before crash"

# Inject a corrupted line into messages.jsonl to test corruption recovery.
printf 'this is NOT json\n' >> .agent-bus/messages.jsonl

# Phase B: send 3 more while watcher is down.
"$AB" send --from claude --to codex --type task --subject "B1" --body "third"  --session $session >/dev/null
"$AB" send --from claude --to codex --type task --subject "B2" --body "fourth" --session $session >/dev/null
"$AB" send --from claude --to codex --type task --subject "B3" --body "fifth"  --session $session >/dev/null

# Restart watcher, drain via --once (and a small loop guard).
"$AB" watch --as codex --session "$session" --once >> "$watch_log"
# After --once, more msgs may arrive between phases of the loop; we sent already.
# Ensure delivery: sometimes the corrupt line bumps cursor past one batch — loop until 5 lines or 2s.
deadline=$(($(date +%s) + 3))
while :; do
  total=$(wc -l < "$watch_log" | tr -d ' ')
  [[ "$total" -ge 5 ]] && break
  [[ $(date +%s) -gt $deadline ]] && break
  "$AB" watch --as codex --session "$session" --once >> "$watch_log"
done

total=$(wc -l < "$watch_log" | tr -d ' ')
assert_eq "$total" "5" "all 5 msgs delivered after crash + restart"

# Order check by subject.
order=$(python3 -c "
import json, sys
subs = []
for l in open('$watch_log'):
    if not l.strip(): continue
    subs.append(json.loads(l)['subject'])
print(','.join(subs))
")
assert_eq "$order" "A1,A2,B1,B2,B3" "delivery order preserved across crash"

# Corrupt line warning event emitted with byte_offset.
if grep -q '"event":"corrupt_line_skipped"' .agent-bus/events.jsonl; then
  pass "corrupt_line_skipped event emitted"
else
  fail "no corrupt_line_skipped event"
fi
if grep -q '"byte_offset"' .agent-bus/events.jsonl; then
  pass "byte_offset recorded in warning"
else
  fail "byte_offset missing"
fi

# No duplicates.
dup=$(python3 -c "
import json
ids = [json.loads(l)['id'] for l in open('$watch_log') if l.strip()]
print(len(ids) - len(set(ids)))
")
assert_eq "$dup" "0" "no duplicate deliveries"

finish
