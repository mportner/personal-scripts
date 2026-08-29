#
# File:    launcher_herdr_wiring_test.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Checks that project-sandbox attaches through the shared attach command, so a
# sandbox opened in a herdr pane runs under argv0 claude and herdr's agent
# surface works against it. The unit tests in attach_command_test.sh cover when
# the spoof applies; what is left is the wiring, which only a run of the
# launcher itself exercises. Sourced by test/run.sh.
#
# research-sandbox is not run here. It creates and exits rather than attaching,
# so its only use of the attach command is the hint it prints at the end, and
# that line is past the point --dry-run stops at. Reaching it would mean a real
# clone and a real sandbox.
#
# Every run is a --dry-run against a stub PATH, so nothing here creates a
# sandbox or reaches the network.

PROJECT="$REPO_DIR/bin/project-sandbox.sh"

# gh and op fail, which both launchers read as "could not check". sbx answers
# `ls` with the sandbox name so the launcher takes the attach path, and fails
# everything else, which is as far as a dry run gets anyway.
make_stub_path() {
  # $1 the sandbox name `sbx ls -q` should report
  local stub
  stub="$(new_scratch)/bin"
  mkdir -p "$stub"
  for tool in gh op; do
    printf '#!/bin/sh\nexit 1\n' > "$stub/$tool"
    chmod +x "$stub/$tool"
  done
  # Single-quoted on purpose: the $1 in the format string is the stub's own
  # first argument, read when sbx runs, not this function's.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nif [ "$1" = ls ]; then echo %s; exit 0; fi\nexit 1\n' "$1" \
    > "$stub/sbx"
  chmod +x "$stub/sbx"
  printf '%s' "$stub"
}

attach_line() {
  # $1 value of HERDR_ENV, or "-" for unset. The rest are launcher arguments.
  local home checkout
  home="$(new_scratch)"
  checkout="$(make_checkout)"
  (
    cd "$checkout" || exit 1
    if [[ "$1" == - ]]; then unset HERDR_ENV; else export HERDR_ENV="$1"; fi
    shift
    PATH="$(make_stub_path checkout):$PATH" HOME="$home" \
      SBX_DEV_STATE_ROOT="$home/state" \
      "$PROJECT" --dry-run -y --no-token ${1+"$@"} 2>&1 \
      | grep -E 'would run: (sbx|exec)'
  )
}

# --- the attach the launcher reports is the shared one -----------------------

assert_contains "$(attach_line -)" 'would run: sbx run --name checkout' \
  "outside herdr the attach is the plain command"
assert_contains "$(attach_line 1)" 'would run: exec -a claude sbx run --name checkout' \
  "in a herdr pane the launcher attaches under argv0 claude"
assert_contains "$(attach_line 1 --worktree fix)" \
  'would run: exec -a claude sbx run --name checkout -- --worktree fix' \
  "the worktree the launcher handles is still passed to the agent"
