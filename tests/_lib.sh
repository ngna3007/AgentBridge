# Shared helpers for AgentBridge tests.
# All tests source this file. Provides:
#   AB        — absolute path to scripts/agentbridge
#   workdir   — fresh sandbox via setup_workdir, cd into it
#   pass/fail — colored status
#   assert_eq, assert_contains, assert_not_contains

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AB="$REPO_ROOT/scripts/agentbridge"

if [[ ! -x "$AB" ]]; then
  echo "error: $AB not executable" >&2
  exit 2
fi

TEST_NAME="${TEST_NAME:-$(basename "${BASH_SOURCE[1]:-test}")}"
FAILED=0

if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_BAD=$'\e[31m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
  C_OK=""; C_BAD=""; C_DIM=""; C_RST=""
fi

pass() { echo "${C_OK}PASS${C_RST}  $TEST_NAME :: $*"; }
fail() { echo "${C_BAD}FAIL${C_RST}  $TEST_NAME :: $*" >&2; FAILED=$((FAILED+1)); }

setup_workdir() {
  WORKDIR="$(mktemp -d -t agentbridge-test-XXXXXX)"
  cd "$WORKDIR"
  "$AB" init >/dev/null
}

cleanup_workdir() {
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
    rm -rf "$WORKDIR"
  fi
}

trap cleanup_workdir EXIT

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$label"
  else
    fail "$label  got=[$got] want=[$want]"
  fi
}

assert_contains() {
  local hay="$1" needle="$2" label="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label  needle=[$needle] not in [$hay]"
  fi
}

assert_not_contains() {
  local hay="$1" needle="$2" label="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label  unexpected [$needle] in [$hay]"
  fi
}

finish() {
  if [[ $FAILED -gt 0 ]]; then
    echo "${C_BAD}== $TEST_NAME: $FAILED failure(s) ==${C_RST}" >&2
    exit 1
  fi
  echo "${C_OK}== $TEST_NAME: all assertions passed ==${C_RST}"
}
