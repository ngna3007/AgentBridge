#!/usr/bin/env bash
# AgentBridge 10-minute bootstrap.
# Initializes .agent-bus/ in the current directory and verifies basic flow.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AB="$REPO_ROOT/scripts/agentbridge"

if [[ ! -x "$AB" ]]; then
  echo "error: $AB not found or not executable" >&2
  exit 2
fi

echo "[1/4] init .agent-bus/ in $(pwd)"
"$AB" init

echo "[2/4] smoke send claude → codex"
mid=$("$AB" send --from claude --to codex --type task \
      --subject "bootstrap probe" --body "hello" \
      --session bootstrap)
echo "  -> msg id $mid"

echo "[3/4] codex --once watch"
out=$("$AB" watch --as codex --session bootstrap --once)
echo "  delivered: $out" | head -c 200
echo

echo "[4/4] status"
"$AB" status

echo
echo "Ready. Recommended next:"
echo "  tmux:  $AB tmux --session <id>"
echo "  watch: $AB watch --as claude --session <id>"
echo "  send:  $AB send --from claude --to codex --type task --subject ... --session <id>"
