#
# File:    host_excludes_test.sh
# Created: 2026-09-01
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Tests for the three pieces that carry the host's global git excludes into a
# sandbox: resolving which file the host actually uses, building the marked
# block that goes into the container, and the single `sbx exec` that installs
# it.
#
# sbx replaces core.excludesFile inside the container with one of its own, so
# every pattern the user ignores globally rather than in a committed .gitignore
# stops applying. What that costs is a clean checkout reading as dirty, which
# makes project-sandbox's preflight warn about uncommitted changes on a
# repository that has none.
#
# Sourced by test/run.sh.

PROG=personal-scripts-tests
DRY_RUN=0
NAME=test-sandbox
# shellcheck source=../lib/output.sh
source "$REPO_DIR/lib/output.sh"
# shellcheck source=../lib/sandbox-launcher.sh
source "$REPO_DIR/lib/sandbox-launcher.sh"

# --- which file the host uses ------------------------------------------------

# A home directory with nothing in it that git would read, so each case below
# starts from "no global excludes at all" and adds only what it is about.
#
# XDG_CONFIG_HOME is pointed inside it as well: git reads a config from there
# too, and leaving it at the real user's would let their machine decide how
# these tests come out.
fake_home() {
  local home
  home="$(new_scratch)/home"
  mkdir -p "$home/.config"
  printf '%s' "$home"
}

# Runs host_excludes_file against a home of its own. Prints what it resolved,
# which is a path or nothing at all.
resolved() {
  # $1 home directory
  ( HOME="$1"; XDG_CONFIG_HOME="$1/.config"; host_excludes_file )
}

# A configured file that exists is the whole point, and the common case.
h="$(fake_home)"
printf '.DS_Store\n' > "$h/.gitignore_global"
printf '[core]\n\texcludesFile = %s\n' "$h/.gitignore_global" > "$h/.gitconfig"
assert_equals "$h/.gitignore_global" "$(resolved "$h")" \
  "a configured excludes file that exists is the one to carry"

# Written with a tilde far more often than with an absolute path, and a literal
# "~/..." handed to the container would be a path that does not exist there.
# git expands this itself for a value it is asked for as a path, which is why
# the resolution asks that way rather than expanding by hand.
h="$(fake_home)"
printf '.DS_Store\n' > "$h/.gitignore_global"
printf '[core]\n\texcludesFile = ~/.gitignore_global\n' > "$h/.gitconfig"
assert_equals "$h/.gitignore_global" "$(resolved "$h")" \
  "a tilde in the configured path is expanded"

# Configured but absent. Nothing to carry, and no reason to fall back: git is
# not reading anything here either, so the sandbox already matches the host.
h="$(fake_home)"
printf '[core]\n\texcludesFile = %s/nope\n' "$h" > "$h/.gitconfig"
assert_equals "" "$(resolved "$h")" \
  "a configured path that does not exist resolves to nothing"

# Unset is not the same as none. git falls back to the XDG path, so a user who
# has never set core.excludesFile can still have a global ignore file, and it
# is the fallback that finds it.
h="$(fake_home)"
mkdir -p "$h/.config/git"
printf '.DS_Store\n' > "$h/.config/git/ignore"
assert_equals "$h/.config/git/ignore" "$(resolved "$h")" \
  "an unset excludesFile falls back to the XDG ignore file"

# The fallback has to honour XDG_CONFIG_HOME rather than hardcoding ~/.config,
# because git does.
h="$(fake_home)"
mkdir -p "$h/elsewhere/git"
printf '.DS_Store\n' > "$h/elsewhere/git/ignore"
assert_equals "$h/elsewhere/git/ignore" \
  "$( HOME="$h"; XDG_CONFIG_HOME="$h/elsewhere"; host_excludes_file )" \
  "the XDG fallback follows XDG_CONFIG_HOME"

# The common case for anyone who is not this repository's author. It has to be
# silent and successful, not an error.
h="$(fake_home)"
assert_equals "" "$(resolved "$h")" \
  "a host with no global excludes at all resolves to nothing"

# A directory at the configured path is not a file to read. Worth its own case
# because -e would accept it and the carry would then ship a read error.
h="$(fake_home)"
mkdir -p "$h/adirectory"
printf '[core]\n\texcludesFile = %s/adirectory\n' "$h" > "$h/.gitconfig"
assert_equals "" "$(resolved "$h")" \
  "a directory at the configured path resolves to nothing"

# --- the block that goes into the container ----------------------------------

# The markers are what make this rewritable. Attach runs against a container
# that already has a block, so the container strips between the markers before
# appending, and a run that changes nothing leaves the file as it found it.
h="$(fake_home)"
printf '*~\n.DS_Store\n' > "$h/ignore"
block="$(excludes_block "$h/ignore")"
assert_contains "$block" "$EXCLUDES_BEGIN" "the block opens with the begin marker"
assert_contains "$block" "$EXCLUDES_END" "the block closes with the end marker"
assert_contains "$block" ".DS_Store" "the block carries the host's patterns"

# Order matters: content between the markers, not around them. Checked as a
# whole string rather than by grepping for each part, which would pass on a
# block that had them in any order.
assert_equals "$EXCLUDES_BEGIN
*~
.DS_Store
$EXCLUDES_END" "$block" "the block is the markers wrapped around the content"

# A file with no trailing newline is normal (an editor that does not add one),
# and joining its last line onto the end marker would both lose the pattern and
# leave a block the container cannot find the end of.
h="$(fake_home)"
printf '*~\n.DS_Store' > "$h/ignore"
assert_equals "$EXCLUDES_BEGIN
*~
.DS_Store
$EXCLUDES_END" "$(excludes_block "$h/ignore")" \
  "a source file with no trailing newline still ends the block on its own line"

# An empty file is not the same as no file: the user has one and it is empty,
# so the block is still written and still strips whatever a previous run left.
h="$(fake_home)"
: > "$h/ignore"
assert_equals "$EXCLUDES_BEGIN
$EXCLUDES_END" "$(excludes_block "$h/ignore")" \
  "an empty source file makes an empty block, not a missing one"

# --- the call that installs it -----------------------------------------------

# The container side is a single `sbx exec`, so a shell function shadowing sbx
# is enough to see exactly what it was asked to do. Recorded one argument per
# line, because the payload is one argument and splitting on spaces would not
# tell an argument boundary from a space inside one.
STUB_ARGV=""
STUB_RC=0
sbx() {
  local a
  for a in "$@"; do printf '%s\n' "$a"; done > "$STUB_ARGV"
  return "$STUB_RC"
}

# Runs the carry against a home of its own and a recording sbx. Prints what the
# function itself said; what it asked sbx to do is left in STUB_ARGV.
carry() {
  # $1 home directory, $2 DRY_RUN, $3 the status sbx returns
  ( HOME="$1"; XDG_CONFIG_HOME="$1/.config"
    DRY_RUN="$2"; STUB_RC="$3"
    carry_host_excludes 2>&1 )
}

argv_of() {
  # The value of an environment argument the stub recorded, by name.
  grep "^$1=" "$STUB_ARGV" | sed "s/^$1=//"
}

h="$(fake_home)"
printf '*~\n.DS_Store\n' > "$h/.gitignore_global"
printf '[core]\n\texcludesFile = %s/.gitignore_global\n' "$h" > "$h/.gitconfig"
STUB_ARGV="$(new_scratch)/argv"

out="$(carry "$h" 0 0)"
argv="$(cat "$STUB_ARGV")"
assert_contains "$argv" "exec" "the carry runs sbx exec"
assert_contains "$argv" "$NAME" "the carry names the sandbox"

# Passed base64 rather than as text: a gitignore is full of the characters a
# shell would otherwise act on, and this crosses two shells and a CLI argument
# parser to get where it is going.
assert_equals "$EXCLUDES_BEGIN
*~
.DS_Store
$EXCLUDES_END" "$(argv_of PS_EXCLUDES_BLOCK | base64 -d)" \
  "the block reaches the container intact"

# The container strips its previous block before appending, and it needs the
# same markers to find it. Passed rather than duplicated in the container
# script, so there is one spelling of them and not two that can drift.
assert_equals "$EXCLUDES_BEGIN" "$(argv_of PS_EXCLUDES_BEGIN)" \
  "the begin marker is passed to the container"
assert_equals "$EXCLUDES_END" "$(argv_of PS_EXCLUDES_END)" \
  "the end marker is passed to the container"

assert_contains "$out" "excludes" "the carry says what it did"

# A host with nothing to carry must not touch the container at all, must not
# read as a failure, and must say nothing whatsoever. This is what most machines
# running this will do, and it runs at every attach as well as at creation, so a
# line reporting the non-event would be recurring noise. Silence includes the
# step header, which is why the function prints that itself rather than leaving
# it to the callers.
h="$(fake_home)"
: > "$STUB_ARGV"
out="$(carry "$h" 0 0)"
assert_equals "" "$(cat "$STUB_ARGV")" "nothing to carry does not call sbx"
assert_equals "" "$out" "nothing to carry says nothing at all"

# --dry-run reports without doing. The carry cannot go through run(), which
# cannot express the capture this needs, so it has to honour DRY_RUN itself.
h="$(fake_home)"
printf '.DS_Store\n' > "$h/.gitignore_global"
printf '[core]\n\texcludesFile = %s/.gitignore_global\n' "$h" > "$h/.gitconfig"
: > "$STUB_ARGV"
out="$(carry "$h" 1 0)"
assert_equals "" "$(cat "$STUB_ARGV")" "a dry run does not call sbx"
assert_contains "$out" "would carry" "a dry run says what it would carry"
assert_contains "$out" "$h/.gitignore_global" "a dry run names the file"

# The sandbox is fine and worth keeping when only this fails, so the carry
# warns rather than dying. Silence would be worse than either: the whole point
# is that a dirty-looking checkout has an explanation.
h="$(fake_home)"
printf '.DS_Store\n' > "$h/.gitignore_global"
printf '[core]\n\texcludesFile = %s/.gitignore_global\n' "$h" > "$h/.gitconfig"
out="$(carry "$h" 0 1)"
assert_contains "$out" "WARNING" "a failed carry warns"

# Returning non-zero would abort the caller under set -e, and this is not worth
# taking a created sandbox down for.
( HOME="$h"; XDG_CONFIG_HOME="$h/.config"; DRY_RUN=0; STUB_RC=1
  carry_host_excludes >/dev/null 2>&1 )
assert_equals "0" "$?" "a failed carry does not fail the caller"

# --- the script the container runs -------------------------------------------

# Run for real under sh, against a temp HOME, rather than through a stubbed sbx.
# The strip-and-append below is the half that implements "rewrite the block
# rather than duplicate it", so a suite that only stubbed sbx would be asserting
# that behaviour in prose and testing none of it.
#
# GIT_CONFIG_GLOBAL rather than HOME alone, because the script asks git where to
# write with `git config --global` and this is what makes that answer the temp
# file instead of the real user's.
install_into() {
  # $1 the excludes file's starting contents, "-" for a file that does not
  # exist yet. $2 the patterns to carry. Prints the resulting file.
  local dir dest block
  dir="$(new_scratch)"
  dest="$dir/excludes"
  [[ "$1" == - ]] || printf '%s' "$1" > "$dest"
  printf '[core]\n\texcludesFile = %s\n' "$dest" > "$dir/gitconfig"

  printf '%s' "$2" > "$dir/source"
  block="$(excludes_block "$dir/source" | base64 | tr -d '\n')"

  ( GIT_CONFIG_GLOBAL="$dir/gitconfig" HOME="$dir" \
    PS_EXCLUDES_BLOCK="$block" \
    PS_EXCLUDES_BEGIN="$EXCLUDES_BEGIN" \
    PS_EXCLUDES_END="$EXCLUDES_END" \
    sh -c "$EXCLUDES_INSTALL_SH" ) || { fail "install script failed"; return 1; }

  # Reported alongside the contents so a leaked temp file fails a test rather
  # than being noticed later: the script writes beside the excludes file, and
  # clutter there is the exact complaint this whole feature answers.
  local leaked
  leaked="$(find "$dir" -name 'excludes.personal-scripts.*' | wc -l | tr -d ' ')"
  assert_equals "0" "$leaked" "the install leaves no temp file behind"
  cat "$dest"
}

# sbx's own entry has to survive, since replacing its file rather than adding to
# it would take the sandbox's own ignore rule with it.
assert_equals ".sbx
$EXCLUDES_BEGIN
.DS_Store
$EXCLUDES_END" "$(install_into '.sbx
' '.DS_Store
')" "the block is appended and what was already there is kept"

# The point of the markers. A second run replaces the block it finds rather
# than stacking another, which is what makes running this at every attach safe.
assert_equals ".sbx
$EXCLUDES_BEGIN
NEW-PATTERN
$EXCLUDES_END" "$(install_into ".sbx
$EXCLUDES_BEGIN
OLD-PATTERN
$EXCLUDES_END
" 'NEW-PATTERN
')" "an existing block is replaced, not duplicated"

# A line after the block is not part of it. Worth its own case because the
# strip walks the whole file: a reader that stopped skipping at the wrong place
# would swallow whatever sbx or a later tool appended below.
assert_equals ".sbx
trailing-entry
$EXCLUDES_BEGIN
NEW
$EXCLUDES_END" "$(install_into ".sbx
$EXCLUDES_BEGIN
OLD
$EXCLUDES_END
trailing-entry
" 'NEW
')" "content after an old block survives the rewrite"

# The container may have no excludes file at all if sbx ever stops making one.
assert_equals "$EXCLUDES_BEGIN
.DS_Store
$EXCLUDES_END" "$(install_into - '.DS_Store
')" "an absent excludes file is created rather than erroring"

# The same no-trailing-newline source the block builder handles, carried the
# whole way through: the last pattern has to survive the round trip, not just
# the encode.
assert_equals ".sbx
$EXCLUDES_BEGIN
*~
.DS_Store
$EXCLUDES_END" "$(install_into '.sbx
' '*~
.DS_Store')" "a source with no trailing newline arrives intact"

# An excludes file whose own last line has no newline would otherwise have the
# begin marker appended onto it, producing a line that is neither the entry nor
# a marker and losing both.
assert_equals ".sbx
$EXCLUDES_BEGIN
.DS_Store
$EXCLUDES_END" "$(install_into '.sbx' '.DS_Store
')" "an existing file with no trailing newline does not swallow the marker"
