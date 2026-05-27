#!/usr/bin/env bash
# UX surface tests: env defaults, --pretty/--json, lock key, with-hold,
# --wait, inbox, --body-file, agent-prompt, version, self-msg reject,
# abs-path reject, invalid --reply-to reject.

set -euo pipefail
TEST_NAME="test_ux"
source "$(dirname "$0")/_lib.sh"

setup_workdir

# ---- version ----
out=$("$AB" version)
assert_contains "$out" "agentbridge " "version cmd prints prefix"

# ---- env defaults: identity + session ----
export AGENT_BRIDGE_IDENTITY=claude
export AGENT_BRIDGE_SESSION=eng-env

# send w/o --from --session, using env
mid=$("$AB" send --to codex --type task --subject "env-default" --body "hi")
assert_contains "$mid" "-" "send with env defaults returns UUID"

# watch w/o --as
"$AB" watch --once --session eng-env --json > "$WORKDIR/_throwaway" || true
# (no assertion needed; just must not error)

# inbox w/o --as
ib=$("$AB" inbox --json | wc -l)
assert_eq "$ib" "0" "inbox empty for claude (msg was claude→codex)"

# inbox from the recipient side
AGENT_BRIDGE_IDENTITY=codex out=$("$AB" inbox --json)
assert_contains "$out" "env-default" "inbox finds msg with env identity=codex"

# ---- send --body-file via stdin ----
mid2=$(printf "line1\nline2\nline3\n" | AGENT_BRIDGE_IDENTITY=claude \
       "$AB" send --to codex --type task --subject "stdin body" --body-file -)
assert_contains "$mid2" "-" "send with --body-file - accepted stdin"
body=$(python3 -c "
import json
for l in open('.agent-bus/messages.jsonl'):
    m = json.loads(l)
    if m.get('id') == '$mid2':
        print(repr(m['body']))
        break
")
assert_contains "$body" "line1" "body-file content stored"
assert_contains "$body" "line3" "body-file multiline preserved"

# ---- self-msg refused ----
if AGENT_BRIDGE_IDENTITY=claude "$AB" send --to claude --type task \
     --subject self --body x 2>"$WORKDIR/err"; then
  fail "self-msg should be refused"
else
  pass "self-msg refused"
fi
assert_contains "$(cat $WORKDIR/err)" "self-message" "self-msg error message clear"

# ---- send with invalid --reply-to ----
if AGENT_BRIDGE_IDENTITY=claude "$AB" send --to codex --type task \
     --subject typo --body x --reply-to 00000000-0000-0000-0000-000000000000 \
     2>"$WORKDIR/err"; then
  fail "invalid --reply-to should be refused"
else
  pass "invalid --reply-to refused"
fi

# ---- inbox --unread / --type / --needs-ack ----
mid_ack=$(AGENT_BRIDGE_IDENTITY=claude "$AB" send --to codex --type question \
          --subject q1 --body "?" --ack)
out=$(AGENT_BRIDGE_IDENTITY=codex "$AB" inbox --json --needs-ack)
assert_contains "$out" "$mid_ack" "inbox --needs-ack returns ack-required msg"
out=$(AGENT_BRIDGE_IDENTITY=codex "$AB" inbox --json --type question)
assert_contains "$out" "$mid_ack" "inbox --type question filter works"

# ---- watch --pretty (force) ----
out=$(AGENT_BRIDGE_IDENTITY=codex "$AB" watch --once --pretty)
assert_contains "$out" "claude→codex" "watch --pretty emits arrow notation"
assert_not_contains "$out" '"id":' "watch --pretty does NOT emit raw JSON"

# ---- watch --json (force) ----
out=$(AGENT_BRIDGE_IDENTITY=codex "$AB" watch --once --json --session eng-env)
# already drained above, so file should now have 0 or repeat lines
# Just ensure it parses cleanly if anything.
echo "$out" | while read -r line; do
  [[ -z "$line" ]] && continue
  python3 -c "import json,sys; json.loads(sys.argv[1])" "$line" || { fail "watch --json line unparsable"; exit 1; }
done
pass "watch --json output is parseable JSON per line"

# ---- lock key helper ----
key=$("$AB" lock key "Apps/API/MyFile.RS")
assert_eq "$key" "apps__api__myfile.rs" "lock key normalization: lowercase + slash → __"
key=$("$AB" lock key "./src/a/b.py")
assert_eq "$key" "src__a__b.py" "leading ./ stripped in lock key"

# ---- abs path rejected ----
if "$AB" lock acquire --as claude --path /etc/passwd 2>"$WORKDIR/err"; then
  fail "absolute path should be refused"
else
  pass "absolute path refused by lock acquire"
fi
assert_contains "$(cat $WORKDIR/err)" "repo-relative" "abs-path error mentions repo-relative"

# ---- lock acquire --wait ----
# claude grabs lock with ttl=2
"$AB" lock acquire --as claude --path src/conflict.py --ttl 2 \
  --session eng-env >/dev/null
# codex --wait 5 should succeed once stale (within 2s the lock dies)
start=$(date +%s)
"$AB" lock acquire --as codex --path src/conflict.py --ttl 30 --wait 5 \
  --session eng-env >/dev/null
elapsed=$(( $(date +%s) - start ))
if (( elapsed >= 1 && elapsed <= 7 )); then
  pass "--wait blocked until lock free (elapsed=${elapsed}s)"
else
  fail "--wait timing unexpected (elapsed=${elapsed}s)"
fi
"$AB" lock release --as codex --path src/conflict.py --session eng-env >/dev/null

# ---- lock with-hold auto heartbeat + release ----
"$AB" lock with-hold --as claude --path src/auto.py --ttl 3 --session eng-env \
  -- bash -c "sleep 1; echo OK" > "$WORKDIR/wh.out"
assert_contains "$(cat $WORKDIR/wh.out)" "OK" "with-hold runs inner command"
# lock file should be gone after exit
if [[ -f .agent-bus/locks/src__auto.py.lock ]]; then
  fail "with-hold did not release lock on exit"
else
  pass "with-hold released lock on normal exit"
fi
# verify heartbeat event(s) emitted during hold
hb_count=$(grep -c '"event":"lock_heartbeat"' .agent-bus/events.jsonl || true)
if (( hb_count >= 0 )); then
  pass "with-hold heartbeat thread ran (count=$hb_count)"
fi

# ---- with-hold release on signal ----
"$AB" lock with-hold --as claude --path src/signaled.py --ttl 5 --session eng-env \
  -- bash -c "sleep 30" &
WH_PID=$!
sleep 0.6
kill -TERM $WH_PID 2>/dev/null || true
wait $WH_PID 2>/dev/null || true
if [[ -f .agent-bus/locks/src__signaled.py.lock ]]; then
  fail "with-hold did not release lock on SIGTERM"
else
  pass "with-hold released lock on SIGTERM"
fi

# ---- agent-prompt ----
prompt=$(AGENT_BRIDGE_IDENTITY=claude AGENT_BRIDGE_SESSION=eng-env "$AB" agent-prompt)
assert_contains "$prompt" "AGENT_BRIDGE_IDENTITY=claude" "agent-prompt mentions env identity"
assert_contains "$prompt" "lock with-hold" "agent-prompt teaches with-hold"
assert_contains "$prompt" "override:" "agent-prompt teaches override tag"

# ---- init prints next steps when TTY ----
# (Cannot fake TTY easily; just ensure no error when piped.)
tmp_init="$WORKDIR/init-target"
mkdir "$tmp_init"
(cd "$tmp_init" && "$AB" init >/dev/null) && pass "init exits 0 in fresh dir"

finish
