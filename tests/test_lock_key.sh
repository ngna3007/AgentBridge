#!/usr/bin/env bash
# Lock-key normalization & uniqueness tests.
# Regression coverage for two prior bugs:
#   1. lstrip("./") was a char-set strip, collapsing ../foo, ./foo, ..foo → foo.
#   2. Unescaped `_` in path components let a/b__c and a__b__c collide.

set -euo pipefail
TEST_NAME="test_lock_key"
source "$(dirname "$0")/_lib.sh"

setup_workdir

# ---- `..` segments rejected outright ----
if "$AB" lock key "../foo/bar" 2>"$WORKDIR/err"; then
  fail "../foo/bar should be rejected"
else
  pass "lock key rejects '..' segments"
fi
assert_contains "$(cat $WORKDIR/err)" "must stay inside repo" \
  "'..' rejection mentions repo boundary"

if "$AB" lock acquire --as claude --path "../etc/passwd" \
     --session t 2>"$WORKDIR/err"; then
  fail "lock acquire on ../etc/passwd should be rejected"
else
  pass "lock acquire rejects '..' paths"
fi

# ---- leading ./ stripped ----
key=$("$AB" lock key "./src/a/b.py")
assert_eq "$key" "src__a__b.py" "leading ./ stripped"

key=$("$AB" lock key "././src/a/b.py")
assert_eq "$key" "src__a__b.py" "repeated leading ./ stripped"

# ---- separator collision fixed via `_` escape ----
k1=$("$AB" lock key "a/b__c")
k2=$("$AB" lock key "a__b__c")
if [[ "$k1" == "$k2" ]]; then
  fail "a/b__c and a__b__c must produce distinct keys (got $k1)"
else
  pass "a/b__c and a__b__c map to distinct keys ($k1 vs $k2)"
fi

# ---- escape is reversible-ish (no further collisions) ----
k3=$("$AB" lock key "a_b/c")
k4=$("$AB" lock key "a/b_c")
if [[ "$k3" == "$k4" ]]; then
  fail "a_b/c and a/b_c must produce distinct keys (got $k3)"
else
  pass "underscored-component variants stay distinct"
fi

# ---- legacy case + non-ascii fine ----
key=$("$AB" lock key "Apps/API/MyFile.RS")
assert_eq "$key" "apps__api__myfile.rs" "lowercase + slash → __ preserved"

# ---- absolute paths still rejected at lock acquire boundary ----
if "$AB" lock acquire --as claude --path "/etc/passwd" \
     --session t 2>"$WORKDIR/err"; then
  fail "absolute path should be rejected"
else
  pass "absolute path still rejected"
fi

finish
