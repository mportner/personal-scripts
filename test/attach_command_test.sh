#
# File:    attach_command_test.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Tests the attach command lib/sandbox-launcher.sh builds: whether the sbx
# attach is prefixed with `exec -a claude`, which is what makes herdr recognise
# a sandbox pane as hosting a Claude Code session. Sourced by test/run.sh.

PROG=personal-scripts-tests
DRY_RUN=0
# shellcheck source=../lib/output.sh
source "$REPO_DIR/lib/output.sh"
# shellcheck source=../lib/sandbox-launcher.sh
source "$REPO_DIR/lib/sandbox-launcher.sh"

# The gate reads the environment, so each case runs in its own subshell rather
# than leaving HERDR_ENV set for the next one.
attach_in() {
  # $1 value of HERDR_ENV, or "-" for unset. The rest are agent arguments.
  (
    # Local to this subshell on purpose: that is what keeps one case from
    # setting the gate for the next.
    # shellcheck disable=SC2030
    if [[ "$1" == - ]]; then unset HERDR_ENV; else export HERDR_ENV="$1"; fi
    shift
    NAME=demo
    attach_command ${1+"$@"}
  )
}

# --- the spoof is applied inside a herdr pane and nowhere else ---------------

assert_equals "sbx run --name demo" "$(attach_in -)" \
  "outside herdr the attach is the plain command"
assert_equals "exec -a claude sbx run --name demo" "$(attach_in 1)" \
  "inside a herdr pane the attach runs under argv0 claude"

# Any other value is not a herdr pane. HERDR_ENV=0 is what herdr itself would
# have to be setting for this to matter, but the point is that the gate is an
# equality test rather than a "set at all" test.
assert_equals "sbx run --name demo" "$(attach_in 0)" \
  "HERDR_ENV=0 is not a herdr pane"

# argv0 has to name the agent herdr is being told about, so a launcher starting
# something else must not claim to be a Claude Code session.
assert_equals "sbx run --name demo" \
  "$( (SANDBOX_AGENT=codex; attach_in 1) )" \
  "a non-claude agent is not spoofed"

# --- agent arguments ---------------------------------------------------------

assert_equals "sbx run --name demo -- --worktree fix" "$(attach_in - --worktree fix)" \
  "agent arguments are forwarded after --"
assert_equals "exec -a claude sbx run --name demo -- --worktree fix" \
  "$(attach_in 1 --worktree fix)" \
  "agent arguments survive the spoof"

# The reported command is meant to be the command that runs, so an argument
# that would not survive being pasted back into a shell is quoted. The expected
# value is written the way a shell would take it, not derived from the code.
assert_equals 'sbx run --name demo -- -p fix\ the\ bug' \
  "$(attach_in - -p 'fix the bug')" \
  "an argument with a space is reported quoted"

# An empty argument is a word the agent was given, so it has to stay a word in
# the reported line rather than disappearing into the spaces around it.
assert_equals "sbx run --name demo -- --model ''" "$(attach_in - --model '')" \
  "an empty argument is reported as an empty word"

# --- the attach that actually runs -------------------------------------------

# exec_attach replaces the process, so it runs in a subshell against a stub sbx
# that reports what it was called with. argv0 is not observable from here: the
# kernel drops it when it execs a #! script, and a stub that is not a script
# would mean compiling one in the test. What this pins is the other half, that
# both gates exec the command the shared builder chose, with the agent
# arguments intact.
exec_attach_args() {
  # $1 value of HERDR_ENV. The rest are agent arguments.
  local stub
  stub="$(new_scratch)/bin"
  mkdir -p "$stub"
  # Single-quoted on purpose: $* is the stub's own arguments, read when it runs.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "%%s\\n" "$*"\n' > "$stub/sbx"
  chmod +x "$stub/sbx"
  (
    # Same reason as above: nothing outside this subshell wants either value.
    # shellcheck disable=SC2031
    export PATH="$stub:$PATH" HERDR_ENV="$1"
    shift
    NAME=demo
    exec_attach ${1+"$@"}
  )
}

assert_equals "run --name demo" "$(exec_attach_args 0)" \
  "the plain attach execs sbx run"
assert_equals "run --name demo -- --worktree fix" "$(exec_attach_args 0 --worktree fix)" \
  "the plain attach forwards agent arguments"
assert_equals "run --name demo -- --worktree fix" "$(exec_attach_args 1 --worktree fix)" \
  "the spoofed attach runs the same command"
