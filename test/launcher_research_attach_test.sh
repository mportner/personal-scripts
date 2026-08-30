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

# --- agent_session_count --------------------------------------------------

# A shell function shadows a command of the same name, so this stands in for
# the sbx the lib would otherwise call.
count_with() {
  # $1 what the stub prints for the pgrep call, $2 its exit status, $3 the
  # status `sbx ls --json` reports for the sandbox (default running). The stub
  # reads these from the environment rather than positionally, because it is
  # called with the lib's arguments, not this function's.
  (
    STUB_OUT="$1"
    STUB_RC="$2"
    STUB_STATUS="${3:-running}"
    # $4 replaces PATH, which is how the jq-missing branch is reached. The stub
    # below is a shell function, so it survives having PATH emptied.
    [[ -n "${4:-}" ]] && PATH="$4"
    sbx() {
      if [ "$1" = ls ]; then
        printf '{"sandboxes":[{"name":"demo","status":"%s"}]}\n' "$STUB_STATUS"
        return 0
      fi
      printf '%s\n' "$STUB_OUT"
      return "$STUB_RC"
    }
    NAME=demo
    agent_session_count
  )
}

assert_equals "0" "$(count_with 0 1)" \
  "pgrep printing 0 and exiting non-zero counts as no agents"
assert_equals "3" "$(count_with 3 0)" \
  "a plain count is read straight through"
assert_equals "0" "$(count_with 'error: no such sandbox' 1)" \
  "output that is not a number counts as no agents"

# The count is what forces the question, since `sbx exec` would start a stopped
# sandbox to answer it.
assert_equals "0" "$(count_with 9 0 stopped)" \
  "a stopped sandbox reports no agents without being asked"

# Empty, not "0": without jq the status cannot be read, and reporting that as
# no agents would state the opposite of what is known as though it were a fact.
assert_equals "" "$(count_with 9 0 running /nonexistent)" \
  "without jq the count is unknown rather than zero"
