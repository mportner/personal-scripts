#
# File:    check_generated_guidance_test.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Tests for check_generated_guidance() in lib/sandbox-launcher.sh, the after-the
# -fact check both launchers run once a sandbox exists. It reads the first line
# of the CLAUDE.md sbx generates above the workspace and says whether the kit
# trimmed it, so a change to sbx's template cannot turn the fix off quietly.
# Sourced by test/run.sh.

PROG=personal-scripts-tests
DRY_RUN=0
NAME=test-sandbox
# shellcheck source=../lib/output.sh
source "$REPO_DIR/lib/output.sh"
# shellcheck source=../lib/sandbox-launcher.sh
source "$REPO_DIR/lib/sandbox-launcher.sh"

# The check shells out to `sbx exec`, so the sandbox is a stub that prints the
# first line the real one would. "-" stands for a sandbox the read fails in.
run_check() {
  # $1 first line of the generated file, or "-" for a failing read
  local stub
  stub="$(new_scratch)/bin"
  mkdir -p "$stub"
  if [[ "$1" == - ]]; then
    printf '#!/bin/sh\nexit 1\n' > "$stub/sbx"
  else
    printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$(printf '%q' "$1")" > "$stub/sbx"
  fi
  chmod +x "$stub/sbx"
  ( PATH="$stub:$PATH"; check_generated_guidance 2>&1 )
}

out="$(run_check "$GUIDANCE_MARKER")"
assert_contains "$out" 'guidance  trimmed' "reports a trimmed file"
assert_not_contains "$out" 'WARNING' "does not warn about a trimmed file"

out="$(run_check '# Project Guidance')"
assert_contains "$out" 'WARNING' "warns when the file was left generated"
assert_contains "$out" '# Project Guidance' "quotes the first line it found"
assert_contains "$out" 'trim-sandbox-guidance.sh' "points at the script that should have run"

out="$(run_check '')"
assert_contains "$out" 'nothing generated above the workspace' "reports an absent file"
assert_not_contains "$out" 'WARNING' "does not warn when there is no file"

out="$(run_check -)"
assert_contains "$out" 'nothing generated above the workspace' "treats an unreadable sandbox as absent"
assert_not_contains "$out" 'WARNING' "does not warn when the read fails"
