#
# File:    launcher_shared_test.sh
# Created: 2026-08-30
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Covers the shapes both launchers used to carry their own copy of, now in
# lib/sandbox-launcher.sh: the two spellings of --worktree and the name they
# insist on, whether a sandbox exists, and the argument list the agent is
# started with.
#
# Unit tests, so what they pin is the shared behaviour itself. That both
# launchers actually reach it is pinned by the wiring tests,
# launcher_herdr_wiring_test.sh and launcher_research_attach_test.sh, which run
# the launchers end to end against a stub PATH.
#
# Sourced by test/run.sh.

PROG=personal-scripts-tests
DRY_RUN=0
# shellcheck source=../lib/output.sh
source "$REPO_DIR/lib/output.sh"
# shellcheck source=../lib/sandbox-launcher.sh
source "$REPO_DIR/lib/sandbox-launcher.sh"

# --- the flag pair -----------------------------------------------------------

# take_worktree_flag reports through globals and can exit, so each case runs in
# its own subshell and reports back as one line: the exit status, the name it
# took, and how many arguments the caller should shift.
flag() {
  (
    WORKTREE=""
    WORKTREE_SEEN=0
    WORKTREE_SHIFT=0
    if take_worktree_flag ${1+"$@"}; then rc=0; else rc=$?; fi
    printf '%s %s %s %s' "$rc" "${WORKTREE:--}" "$WORKTREE_SEEN" "$WORKTREE_SHIFT"
  )
}

# The shift count is the whole point of the return value: the flag and its
# value are two words, the joined spelling is one, and a caller that shifts the
# wrong number either loses an argument or reads the name as one.
assert_equals "0 fix 1 2" "$(flag -w fix)" \
  "-w NAME takes the name and consumes two arguments"
assert_equals "0 fix 1 2" "$(flag --worktree fix)" \
  "--worktree NAME takes the name and consumes two arguments"
assert_equals "0 fix 1 1" "$(flag --worktree=fix)" \
  "--worktree=NAME takes the name and consumes one argument"

# Anything else is the caller's to deal with, untouched.
assert_equals "1 - 0 0" "$(flag --dry-run)" \
  "another option is not a worktree flag"
assert_equals "1 - 0 0" "$(flag owner/repo)" \
  "a positional argument is not a worktree flag"

# A name that is really the next option is the case worth having a test for:
# without it the worktree is named after that flag and the flag is silently
# eaten.
assert_contains "$(flag -w --dry-run 2>&1)" '--worktree needs a name' \
  "an option where the name goes is rejected"
assert_contains "$(flag --worktree 2>&1)" '--worktree needs a name' \
  "a trailing --worktree with no name is rejected"
assert_contains "$(flag --worktree= 2>&1)" '--worktree needs a name' \
  "--worktree= with nothing after it is rejected"

# --- the reason the name is insisted on --------------------------------------

# The rule is shared; why it exists is not. project-sandbox pre-creates the
# worktree and isolates its node_modules, research-sandbox forwards the flag
# and pre-creates nothing, so the explanation is the caller's to supply.
assert_contains "$(WORKTREE_NAME_REASON='because reasons' flag --worktree 2>&1)" \
  'because reasons' \
  "the caller's reason is part of the message"
assert_not_contains "$(flag --worktree 2>&1)" 'because reasons' \
  "a launcher with no reason to give gets the bare message"

# --- what the agent is started with ------------------------------------------

args() {
  # $1 the worktree, empty for none. The rest are the caller's own agent
  # arguments. Reported as a count and then each word in brackets: an empty
  # argument is still a word, and a bare list would lose it in the spaces.
  local a
  (
    WORKTREE="$1"
    shift
    build_attach_args ${1+"$@"}
    printf '%s' "${#ATTACH_ARGS[@]}"
    for a in ${ATTACH_ARGS[@]+"${ATTACH_ARGS[@]}"}; do printf ' [%s]' "$a"; done
  )
}

assert_equals "0" "$(args '')" \
  "no worktree and no arguments is an empty list"
assert_equals "2 [--worktree] [fix]" "$(args fix)" \
  "the worktree is added as a flag and a value, not one word"
assert_equals "4 [--worktree] [fix] [-p] [hi]" "$(args fix -p hi)" \
  "the caller's arguments follow the worktree"
assert_equals "2 [-p] [hi]" "$(args '' -p hi)" \
  "without a worktree only the caller's arguments are passed"
# An empty argument is a word the agent was given and has to stay one.
assert_equals "2 [--model] []" "$(args '' --model '')" \
  "an empty argument stays a word"

# --- whether the sandbox exists ----------------------------------------------

# A shell function shadows the real sbx, and survives into the pipeline
# sandbox_exists runs it in.
STUB_LS=""
STUB_LS_RC=0
sbx() {
  printf '%s' "$STUB_LS"
  return "$STUB_LS_RC"
}

exists_rc() {
  # $1 what `sbx ls -q` prints, $2 its exit status, $3 the name to look for.
  (
    STUB_LS="$1"
    STUB_LS_RC="$2"
    NAME="$3"
    sandbox_exists
    printf '%s' "$?"
  )
}

assert_equals "0" "$(exists_rc 'research-example
other
' 0 research-example)" \
  "a listed sandbox exists"
assert_equals "1" "$(exists_rc 'other
' 0 research-example)" \
  "a sandbox that is not listed does not exist"
# Whole-line match, so a longer name containing this one is not a hit.
assert_equals "1" "$(exists_rc 'research-example-two
' 0 research-example)" \
  "a longer name containing this one is not a match"
# The name matches and sbx still failed, which is the case worth pinning: what
# rejects it is pipefail, which the launchers and this harness both set. With
# an empty listing this would pass whatever sbx returned, and pin nothing.
assert_equals "1" "$(exists_rc 'research-example
' 1 research-example)" \
  "a name listed by a failing sbx is not an existing sandbox"
assert_equals "1" "$(exists_rc '' 1 research-example)" \
  "sbx failing with nothing listed is not an existing sandbox"
