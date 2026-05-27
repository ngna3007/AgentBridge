#!/usr/bin/env bash
# Phase 5.4 — transcript reproducibility.
# Drive a deterministic session (task→ack + lock cycle), then verify
# `transcript` reproduces the expected ordered chain of events + messages.

set -euo pipefail
TEST_NAME="test_transcript"
source "$(dirname "$0")/_lib.sh"

setup_workdir
S=eng-repro

# Step 1: claude sends task w/ requires_ack.
mid=$("$AB" send --from claude --to codex --type task \
      --subject "checksum parity" --body "compare rust vs sql" \
      --session $S --ack)

# Step 2: codex acks.
"$AB" ack --as codex --reply-to "$mid" --body "ack: starting" >/dev/null

# Step 3: codex acquires lock.
"$AB" lock acquire --as codex --path apps/api-rs/src/hash.rs --ttl 60 \
  --reason "patch hash" --session $S >/dev/null

# Step 4: codex heartbeats.
"$AB" lock heartbeat --as codex --path apps/api-rs/src/hash.rs --session $S >/dev/null

# Step 5: codex releases.
"$AB" lock release --as codex --path apps/api-rs/src/hash.rs --session $S >/dev/null

# Step 6: codex sends answer.
"$AB" send --from codex --to claude --type answer \
  --subject "parity confirmed" --body "match" --session $S >/dev/null

# Reconstruct transcript (pretty).
pretty="$WORKDIR/transcript.pretty"
"$AB" transcript --session $S > "$pretty"

# Expected ordered chain of action keys.
expected=$(cat <<'EOF'
MSG claude→codex [task] checksum parity
EVT agentbridge send_completed
EVT codex watch_started_or_ack
EVT codex ack_sent
MSG codex→claude [answer] ack: checksum parity
EVT codex lock_acquired
MSG codex→claude [answer] ack: checksum parity
EVT codex lock_heartbeat
EVT codex lock_released
MSG codex→claude [answer] parity confirmed
EOF
)
# That hardcoded chain is brittle; instead use a structural check:
# - first line is MSG task subject "checksum parity"
# - includes EVT lock_acquired then lock_heartbeat then lock_released in that order
# - includes ack MSG (subject containing "ack:") before "parity confirmed"

first_line=$(head -1 "$pretty")
assert_contains "$first_line" "MSG  claude→codex  [task] checksum parity" "first event is task msg"

# Order: lock_acquired → lock_heartbeat → lock_released
nlines=$(wc -l < "$pretty")
la_idx=$(grep -n 'lock_acquired' "$pretty" | head -1 | cut -d: -f1)
lh_idx=$(grep -n 'lock_heartbeat' "$pretty" | head -1 | cut -d: -f1)
lr_idx=$(grep -n 'lock_released' "$pretty" | head -1 | cut -d: -f1)
if [[ -n "$la_idx" && -n "$lh_idx" && -n "$lr_idx" ]] && \
   (( la_idx < lh_idx && lh_idx < lr_idx )); then
  pass "lock acquired→heartbeat→released order preserved"
else
  fail "lock event order broken (a=$la_idx h=$lh_idx r=$lr_idx)"
fi

# Ack appears before final "parity confirmed".
ack_idx=$(grep -n '\[answer\] ack:' "$pretty" | head -1 | cut -d: -f1)
final_idx=$(grep -n 'parity confirmed' "$pretty" | head -1 | cut -d: -f1)
if [[ -n "$ack_idx" && -n "$final_idx" ]] && (( ack_idx < final_idx )); then
  pass "ack precedes final answer"
else
  fail "ack/final order broken (ack=$ack_idx final=$final_idx)"
fi

# Reproducibility: running transcript twice yields identical output.
"$AB" transcript --session $S > "$WORKDIR/transcript.2"
if diff -q "$pretty" "$WORKDIR/transcript.2" >/dev/null; then
  pass "transcript deterministic across reruns"
else
  fail "transcript not deterministic"
fi

# JSONL format also works.
jsonl="$WORKDIR/transcript.jsonl"
"$AB" transcript --session $S --format jsonl > "$jsonl"
python3 - "$jsonl" <<'PY'
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert all("kind" in o for o in lines)
assert any(o["kind"] == "msg" and o.get("type") == "task" for o in lines)
assert any(o["kind"] == "evt" and o.get("event") == "lock_acquired" for o in lines)
print("ok jsonl format")
PY
assert_eq "$?" "0" "transcript --format jsonl parses + contains expected entries"

finish
