#
# File:    run_test.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Tests for test/run.sh itself. The runner reports what every other test file in
# here is worth, so the one thing it must never do is call a file that ran no
# assertions "ok". Sourced by test/run.sh, which is also the thing under test:
# the inner runs below take an explicit file argument, so they never glob and
# never recurse into this file.

RUNNER="$REPO_DIR/test/run.sh"

# --- a file that does not parse is a failure, not a pass ---------------------

# `source` on a file with a syntax error prints the error, returns non-zero and
# carries on, so a runner that reads only the failure count would call this
# file passing.
out="$("$RUNNER" "$TEST_DIR/fixtures/unparseable-test.sh" 2>&1)"
status=$?
assert_equals 1 "$status" "exits non-zero on a file that does not parse"
assert_contains "$out" 'FAILED' "reports the unparseable file as failed"
assert_contains "$out" '0 passed, 1 failed' "counts it as a failure"

# --- the control still passes ------------------------------------------------

out="$("$RUNNER" "$TEST_DIR/fixtures/passing-test.sh" 2>&1)"
status=$?
assert_equals 0 "$status" "exits 0 on a file that parses and asserts cleanly"
assert_contains "$out" '1 passed, 0 failed' "counts it as a pass"
