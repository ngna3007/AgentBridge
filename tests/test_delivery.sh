#!/usr/bin/env bash
# Phase 5.1 — local delivery latency + ack contract.
# Sends N messages, watcher drains, asserts per-message latency median < 1s
# and that requires_ack messages produce ack records linked via reply_to.

set -euo pipefail
TEST_NAME="test_delivery"
source "$(dirname "$0")/_lib.sh"

setup_workdir
N=10

watch_log="$WORKDIR/watch.out"
"$AB" watch --as codex --session eng-perf > "$watch_log" 2>"$WORKDIR/watch.err" &
WATCH_PID=$!
trap 'kill $WATCH_PID 2>/dev/null || true; cleanup_workdir' EXIT
sleep 0.2

send_log="$WORKDIR/send.log"
: > "$send_log"
for i in $(seq 1 $N); do
  t=$(python3 -c 'import time; print(repr(time.time()))')
  mid=$("$AB" send --from claude --to codex --type task \
        --subject "perf-$i" --body "payload $i" --session eng-perf --ack)
  echo "$i $t $mid" >> "$send_log"
done

# Wait until N lines in watch_log (or 5s timeout).
deadline=$(($(date +%s) + 5))
while :; do
  count=$(wc -l < "$watch_log" 2>/dev/null | tr -d ' ')
  [[ "${count:-0}" -ge "$N" ]] && break
  [[ $(date +%s) -gt $deadline ]] && break
  sleep 0.05
done
count=$(wc -l < "$watch_log" | tr -d ' ')
assert_eq "$count" "$N" "all $N messages delivered"

# Latency analysis in pure python.
WATCH_LOG="$watch_log" SEND_LOG="$send_log" N="$N" \
python3 <<'PY'
import json, os, datetime, statistics, sys
def iso2ts(s):
    s = s.replace("Z","+00:00")
    return datetime.datetime.fromisoformat(s).timestamp()

n = int(os.environ["N"])
sent = {}
for line in open(os.environ["SEND_LOG"]):
    idx, t, mid = line.split()
    sent[int(idx)] = (float(t), mid)

delivered = [json.loads(l) for l in open(os.environ["WATCH_LOG"]) if l.strip()]
assert len(delivered) == n, f"want {n} delivered, got {len(delivered)}"
lats = []
seen_ids = set()
for m in delivered:
    idx = int(m["subject"].split("-")[1])
    assert m["to"] == "codex"
    assert m["session_id"] == "eng-perf"
    assert m["requires_ack"] is True
    assert m["id"] == sent[idx][1], f"id mismatch idx={idx}"
    seen_ids.add(m["id"])
    lats.append(iso2ts(m["ts"]) - sent[idx][0])
assert len(seen_ids) == n, "duplicate delivery"
med = statistics.median(lats)
mx = max(lats)
print(f"latency_median={med:.4f}s latency_max={mx:.4f}s n={len(lats)}")
if med >= 1.0:
    print(f"FAIL: median {med} exceeds 1s budget", file=sys.stderr)
    sys.exit(1)
PY
assert_eq "$?" "0" "median delivery latency < 1s"

kill $WATCH_PID 2>/dev/null || true
wait $WATCH_PID 2>/dev/null || true

# Ack contract.
awk '{print $3}' "$send_log" | while read -r mid; do
  "$AB" ack --as codex --reply-to "$mid" --body "ok" >/dev/null
done

claude_log="$WORKDIR/claude.out"
"$AB" watch --as claude --session eng-perf --once > "$claude_log"
ack_count=$(wc -l < "$claude_log" | tr -d ' ')
assert_eq "$ack_count" "$N" "all $N acks delivered to claude"

SEND_LOG="$send_log" CLAUDE_LOG="$claude_log" python3 <<'PY'
import json, os
ids = {line.split()[2] for line in open(os.environ["SEND_LOG"])}
for line in open(os.environ["CLAUDE_LOG"]):
    if not line.strip(): continue
    m = json.loads(line)
    assert m.get("reply_to") in ids, f"orphan ack reply_to={m.get('reply_to')}"
print("ok all acks reference originals")
PY
assert_eq "$?" "0" "every ack links to a sent message via reply_to"

# ----- Concurrent-send atomicity check -------------------------------------
# Launch K parallel sends. Every appended line must be parseable JSON.
# Tests fcntl.flock + O_APPEND serialization under contention.
K=24
for i in $(seq 1 $K); do
  "$AB" send --from claude --to codex --type status \
    --subject "concurrent-$i" --body "$(python3 -c 'print("x"*400)')" \
    --session eng-concurrent &
done >/dev/null 2>&1
wait

torn=$(python3 - <<'PY'
import json
torn = 0
with open(".agent-bus/messages.jsonl") as f:
    for i, line in enumerate(f, 1):
        line = line.rstrip("\n")
        if not line:
            continue
        try:
            json.loads(line)
        except json.JSONDecodeError:
            torn += 1
print(torn)
PY
)
assert_eq "$torn" "0" "no torn lines after $K concurrent sends"

finish
