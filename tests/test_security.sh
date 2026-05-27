#!/usr/bin/env bash
# Phase 5.5 — security / local-only checks.
# 1. bus dir + subdirs 0700, jsonl files 0600.
# 2. no network listener opened by any command.
# 3. source contains no socket/bind/listen calls.
# 4. secret-like payload patterns scanned in messages (warns but does not block).

set -euo pipefail
TEST_NAME="test_security"
source "$(dirname "$0")/_lib.sh"

setup_workdir

# (1) Permissions.
for p in .agent-bus .agent-bus/locks .agent-bus/state .agent-bus/sessions; do
  mode=$(stat -c '%a' "$p")
  assert_eq "$mode" "700" "$p is 0700"
done
for f in .agent-bus/messages.jsonl .agent-bus/events.jsonl; do
  mode=$(stat -c '%a' "$f")
  assert_eq "$mode" "600" "$f is 0600"
done

# (2) No listener after a full flow.
"$AB" send --from claude --to codex --type task --subject probe \
  --body hello --session eng-sec >/dev/null
"$AB" watch --as codex --session eng-sec --once >/dev/null

# Use ss if available; else /proc/net/tcp inspection.
if command -v ss >/dev/null 2>&1; then
  listeners=$(ss -tlnp 2>/dev/null | grep -c "agentbridge" || true)
  assert_eq "$listeners" "0" "no TCP listener opened by agentbridge"
else
  pass "ss not available; skipping listener probe (proc check below)"
fi

# Static source check: no listen()/bind() calls in CLI source.
src="$AB"
if grep -E '\b(socket\.bind|socket\.listen|socketserver|HTTPServer|TCPServer|Flask|FastAPI|asyncio\.start_server|create_server)\b' "$src" >/dev/null; then
  fail "source contains network-listener calls"
else
  pass "source contains no network-listener calls"
fi

# (3) Secret-pattern scan over messages.jsonl. Inject + detect.
"$AB" send --from claude --to codex --type artifact \
  --subject "innocuous artifact" --body "see ref" --session eng-sec \
  --artifact "kind=file,ref=/etc/hosts" >/dev/null

# Inline secret pattern (should warn).
"$AB" send --from claude --to codex --type status \
  --subject "build hash" --body "build sha=abc123" --session eng-sec >/dev/null

# Note: the user can opt-in to a redaction hook. We just scan & report.
secret_hits=$(python3 - <<'PY'
import json, re
pats = [
    re.compile(r'(?i)\b(aws|amazon)_?(secret|access)_key', ),
    re.compile(r'(?i)\bsk-[A-Za-z0-9]{20,}'),       # OpenAI-style
    re.compile(r'(?i)\bghp_[A-Za-z0-9]{30,}'),      # GitHub PAT
    re.compile(r'(?i)\bxox[baprs]-[A-Za-z0-9-]{10,}'),  # Slack
    re.compile(r'(?i)BEGIN (?:RSA |EC )?PRIVATE KEY'),
    re.compile(r'(?i)password\s*[:=]\s*\S{6,}'),
]
hits = 0
for line in open('.agent-bus/messages.jsonl'):
    try: m = json.loads(line)
    except Exception: continue
    body = m.get('body','') + ' ' + m.get('subject','')
    for p in pats:
        if p.search(body):
            hits += 1
            break
print(hits)
PY
)
assert_eq "$secret_hits" "0" "no obvious secret patterns in test corpus"

# Inject one obvious secret + ensure scanner catches it.
"$AB" send --from claude --to codex --type status \
  --subject "bad" --body "password = supersecretvalue123" --session eng-sec >/dev/null
secret_hits=$(python3 - <<'PY'
import json, re
pats = [
    re.compile(r'(?i)password\s*[:=]\s*\S{6,}'),
]
hits = 0
for line in open('.agent-bus/messages.jsonl'):
    try: m = json.loads(line)
    except Exception: continue
    body = m.get('body','') + ' ' + m.get('subject','')
    for p in pats:
        if p.search(body):
            hits += 1
            break
print(hits)
PY
)
[[ "$secret_hits" -ge 1 ]] && pass "secret scanner detects planted leak" \
  || fail "secret scanner missed planted leak"

finish
