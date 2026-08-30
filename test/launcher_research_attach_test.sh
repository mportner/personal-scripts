#
# File:    launcher_research_attach_test.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Covers research-sandbox's attach mode: the command it builds, the worktree it
# forwards, and the warning it prints when another agent is already running in
# the sandbox and would be sharing a working tree with this one.
#
# The create path is not exercised here. It clones from GitHub and creates a
# real sandbox, which is why launcher_herdr_wiring_test.sh only runs
# project-sandbox. Attach reaches neither, so it can be driven end to end
# against a stub PATH.
#
# Sourced by test/run.sh.

PROG=personal-scripts-tests
DRY_RUN=0
# shellcheck source=../lib/output.sh
source "$REPO_DIR/lib/output.sh"
# shellcheck source=../lib/sandbox-launcher.sh
source "$REPO_DIR/lib/sandbox-launcher.sh"

RESEARCH="$REPO_DIR/bin/research-sandbox.sh"

# gh and op fail, which the launcher reads as "could not check". sbx answers
# `ls` with the sandbox name so the attach finds it, and `exec` with an agent
# count, which is what agent_session_count reads.
make_stub_path() {
  # $1 name `sbx ls -q` reports, $2 count `sbx exec ... pgrep` reports
  local stub
  stub="$(new_scratch)/bin"
  mkdir -p "$stub"
  for tool in gh op; do
    printf '#!/bin/sh\nexit 1\n' > "$stub/$tool"
    chmod +x "$stub/$tool"
  done
  # Quoted heredoc, so the $1 and $2 inside stay the stub's own arguments,
  # read when sbx runs, rather than this function's. The two values it has to
  # carry are substituted afterwards. `ls -q` and `ls --json` answer
  # differently because the launcher asks both: one for whether the sandbox
  # exists, the other for whether it is running.
  cat > "$stub/sbx" <<'STUB'
#!/bin/sh
if [ "$1" = ls ]; then
  if [ "$2" = --json ]; then
    printf '{"sandboxes":[{"name":"__NAME__","status":"running"}]}\n'
  else
    echo __NAME__
  fi
  exit 0
fi
if [ "$1" = exec ]; then echo __COUNT__; exit 0; fi
exit 1
STUB
  # -i.bak rather than -i '': the empty-argument form is BSD-only and GNU sed
  # reads it as the next expression. The backup is removed either way.
  sed -i.bak "s/__NAME__/$1/g; s/__COUNT__/$2/g" "$stub/sbx"
  rm -f "$stub/sbx.bak"
  chmod +x "$stub/sbx"
  printf '%s' "$stub"
}

run_attach() {
  # $1 value of HERDR_ENV, or "-" for unset. $2 agents already running.
  # The rest are launcher arguments.
  local home herdr count
  home="$(new_scratch)"
  herdr="$1"
  count="$2"
  shift 2
  (
    if [[ "$herdr" == - ]]; then unset HERDR_ENV; else export HERDR_ENV="$herdr"; fi
    PATH="$(make_stub_path research-example "$count"):$PATH" HOME="$home" \
      RESEARCH_SEED_ROOT="$home/seed" \
      "$RESEARCH" --dry-run -y ${1+"$@"} 2>&1
  )
}

# --- the attach goes through the shared builder ------------------------------

assert_contains "$(run_attach - 0 --attach research-example)" \
  'would run: sbx run --name research-example' \
  "attach reports the shared attach command"

assert_contains "$(run_attach 1 0 --attach research-example)" \
  'would run: exec -a claude sbx run --name research-example' \
  "in a herdr pane the attach runs under argv0 claude"

# --- the worktree reaches the agent ------------------------------------------

assert_contains "$(run_attach - 0 --attach research-example -w fix)" \
  'would run: sbx run --name research-example -- --worktree fix' \
  "--worktree is forwarded to the agent"

assert_contains "$(run_attach - 0 --attach research-example --worktree=fix)" \
  'would run: sbx run --name research-example -- --worktree fix' \
  "--worktree=NAME is accepted too"

# --- agents already running --------------------------------------------------

assert_contains "$(run_attach - 2 --attach research-example)" \
  'agents running     2' \
  "attach reports how many agents are already in the sandbox"

assert_contains "$(run_attach - 2 --attach research-example)" \
  'shares the working tree' \
  "attaching alongside another agent without a worktree warns"

assert_not_contains "$(run_attach - 2 --attach research-example -w fix)" \
  'shares the working tree' \
  "a worktree of its own is not warned about"

assert_not_contains "$(run_attach - 0 --attach research-example)" \
  'shares the working tree' \
  "the first agent in a sandbox is not warned about"

# --- usage errors ------------------------------------------------------------

assert_contains "$(run_attach - 0 --worktree fix 2>&1)" \
  '--worktree only applies when attaching' \
  "--worktree outside attach is rejected"

# Otherwise the worktree is named after the flag that followed it, and that
# flag is silently eaten.
assert_contains "$(run_attach - 0 --attach research-example --worktree --dry-run 2>&1)" \
  '--worktree needs a name' \
  "an option where the worktree name goes is rejected"

assert_contains "$(run_attach - 0 --attach no-such-sandbox 2>&1)" \
  'no sandbox named' \
  "attaching to a sandbox that does not exist is rejected"

assert_contains "$(run_attach - 0 --attach mportner/example 2>&1)" \
  'is a repository, not a sandbox name' \
  "a repository passed where the sandbox name goes says so"

# --- sandbox_running and agent_session_count --------------------------------

# One stub for both. A shell function shadows the real sbx and survives PATH
# being emptied, which is how the jq-missing branch is reached. An empty
# STUB_STATUS stands for a sandbox sbx does not list at all.
STUB_OUT=""
STUB_RC=0
STUB_STATUS=running
STUB_LS_RC=0
sbx() {
  if [ "$1" = ls ]; then
    if [ -z "$STUB_STATUS" ]; then
      printf '{"sandboxes":[]}\n'
    else
      printf '{"sandboxes":[{"name":"demo","status":"%s"}]}\n' "$STUB_STATUS"
    fi
    return "$STUB_LS_RC"
  fi
  printf '%s\n' "$STUB_OUT"
  return "$STUB_RC"
}

running_rc() {
  # $1 status ('' for a sandbox that is not listed), $2 `sbx ls` exit status,
  # $3 PATH to run under. Prints sandbox_running's exit status.
  (
    STUB_STATUS="$1"
    STUB_LS_RC="${2:-0}"
    if [ -n "${3:-}" ]; then PATH="$3"; fi
    NAME=demo
    sandbox_running
    printf '%s' "$?"
  )
}

count_with() {
  # $1 pgrep output, $2 pgrep exit status, $3 sandbox status (default running,
  # pass '' for not listed), $4 `sbx ls` exit status.
  (
    STUB_OUT="$1"
    STUB_RC="$2"
    STUB_STATUS="${3-running}"
    STUB_LS_RC="${4:-0}"
    NAME=demo
    agent_session_count
  )
}

# The 1-versus-2 split is what keeps an unreadable status from being reported
# as "nothing is running here".
assert_equals "0" "$(running_rc running)" \
  "a running sandbox reports running"
assert_equals "1" "$(running_rc stopped)" \
  "a stopped sandbox is a definitive no, not an unknown"
assert_equals "2" "$(running_rc '')" \
  "a sandbox sbx does not list is unknown, not stopped"
assert_equals "2" "$(running_rc running 1)" \
  "sbx failing to answer is unknown, not stopped"
assert_equals "2" "$(running_rc running 0 /nonexistent)" \
  "without jq the status cannot be read, so it is unknown"

assert_equals "3" "$(count_with 3 0)" \
  "a plain count is read straight through"
# pgrep exits 1 when nothing matches, having printed a perfectly good 0. That
# is a known zero and must not be laundered into unknown.
assert_equals "0" "$(count_with 0 1)" \
  "pgrep printing 0 and exiting non-zero is a known zero"
# The count is what forces the status question, since `sbx exec` would start a
# stopped sandbox to answer it.
assert_equals "0" "$(count_with 9 0 stopped)" \
  "a stopped sandbox reports no agents without being asked"
assert_equals "" "$(count_with 9 0 running 1)" \
  "an unreadable status gives an unknown count rather than zero"
assert_equals "" "$(count_with 'error: no such sandbox' 1)" \
  "output that is not a number is unknown rather than zero"
