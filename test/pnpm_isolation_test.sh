#
# File:    pnpm_isolation_test.sh
# Created: 2026-09-03
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Tests the preflight that refuses to attach when pnpm would write into the
# mounted checkout.
#
# The failure this guards is silent by construction: a sandbox whose store and
# virtual store are not on the volume looks exactly like one whose are, right
# up to the point several hundred packages into an install where the packages
# have been written into a tree the container's own platform cannot share.
# Nothing reports it, because nothing is broken from the container's point of
# view.
#
# Split into a probe that only gathers facts and a verdict that only judges
# them, so the judging is testable without a container. Both are tested here:
# the probe against stub `pnpm` and `stat`, the verdict against the lines a
# probe would print.
#
# Sourced by test/run.sh.

PROG=personal-scripts-tests
DRY_RUN=0
NAME=test-sandbox
# shellcheck source=../lib/output.sh
source "$REPO_DIR/lib/output.sh"
# shellcheck source=../lib/sandbox-launcher.sh
source "$REPO_DIR/lib/sandbox-launcher.sh"

# --- the verdict -------------------------------------------------------------

# The lines a healthy sandbox's probe prints. Every case below starts from this
# and changes the one field it is about, so a test says what it is testing by
# what it overrides rather than by a wall of near-identical fixtures.
healthy() {
  printf 'workspace=/checkout/example\n'
  printf 'store=/var/lib/pnpm/store\n'
  printf 'vtype=global\n'
  printf 'wsdev=54\n'
  printf 'voldev=65168\n'
  printf 'rootdev=29\n'
  printf 'hardlink=yes\n'
}

# healthy() with one field replaced. The probe prints one key per line, so a
# whole-line substitution is exact and needs no parsing.
with() {
  # $1 key, $2 new value
  healthy | sed "s|^$1=.*|$1=$2|"
}

# The case that must pass, and the only one. Everything below is a way of being
# wrong, so a verdict that accepted them all would still pass this one.
verdict="$(pnpm_isolation_verdict "$(healthy)")"
rc=$?
assert_equals 0 "$rc" "a store on the volume with a global virtual store passes"
assert_equals "" "$verdict" "and says nothing when it passes"

# Not the same as a store that is merely elsewhere: a store under the workspace
# is the whole failure, written directly into the mounted checkout.
verdict="$(pnpm_isolation_verdict "$(with store /checkout/example/.pnpm-store)")"
rc=$?
assert_equals 1 "$rc" "rejects a store inside the workspace"
assert_contains "$verdict" "inside the workspace" "and says so"

# A store that is off the workspace and still not on the volume: it works, it
# is not the sized filesystem the kit declares, and it goes when the container
# does. Nothing about the workspace can catch this, which is why the volume is
# checked by name rather than by "somewhere other than the checkout".
verdict="$(pnpm_isolation_verdict "$(with store /home/agent/.local/share/pnpm/store)")"
rc=$?
assert_equals 1 "$rc" "rejects a store that is off the workspace but not on the volume"
assert_contains "$verdict" "not on the /var/lib/pnpm volume" "and says where it should be"

# The case an earlier version of this check got wrong, and the reason the probe
# reports the volume's device at all. A sandbox created before the volume was
# declared never grows one, because volumes are settled at creation. Comparing
# the store's device against the workspace's does NOT catch it: the workspace
# is virtiofs and the container filesystem is not, so the two differ and the
# check passes. Measured in a real pre-volume sandbox: root 29, workspace 54,
# and /var/lib/pnpm absent entirely, which is what this feeds back.
verdict="$(pnpm_isolation_verdict "$(healthy | sed 's|^voldev=.*|voldev=|')")"
rc=$?
assert_equals 1 "$rc" "rejects a sandbox created before the volume existed"
assert_contains "$verdict" "no /var/lib/pnpm volume" "and says the volume is missing"

# The path is there and nothing is mounted under it, so it is an ordinary
# directory on the container filesystem. Reads correctly, is not a volume.
verdict="$(pnpm_isolation_verdict "$(with voldev 29)")"
rc=$?
assert_equals 1 "$rc" "rejects a volume path that is really just a directory"
assert_contains "$verdict" "plain directory" "and says what it actually is"

# The quiet one. pnpm 11.22 and older have no virtualStoreType at all, so a
# project pinning one of them ignores the setting and leaves the virtual store
# in the tree while the store above it has already moved to the volume. pnpm
# then cannot hardlink between them and writes a full copy of every package
# into the checkout. Verified against pnpm 11.17.0, where `pnpm config get
# virtual-store-type` answers `undefined` while store-dir answers correctly.
verdict="$(pnpm_isolation_verdict "$(with vtype '')")"
rc=$?
assert_equals 1 "$rc" "rejects a virtual store that is not global"
assert_contains "$verdict" "virtual store" "and says which half is wrong"

# Paths can all be right and the volume still be unusable: the startup chown is
# allowed to fail without taking the container down with it, and a store the
# agent cannot write is a sandbox that cannot install anything.
verdict="$(pnpm_isolation_verdict "$(with hardlink no)")"
rc=$?
assert_equals 1 "$rc" "rejects a store that cannot be written and hardlinked"

# An empty store reads as "pnpm could not be asked", which is a different
# failure from any of the above and must not be reported as a bad path.
verdict="$(pnpm_isolation_verdict "$(with store '')")"
rc=$?
assert_equals 1 "$rc" "rejects a probe that could not read pnpm's configuration"
assert_not_contains "$verdict" "inside the workspace" \
  "without also blaming the path it never learned"

# A pnpm that cannot start reports no store, no virtual store type and no
# hardlink, and all three are the same fault. Observed against a real sandbox
# whose pnpm was failing on startup: three findings where one was true.
verdict="$(pnpm_isolation_verdict "$(healthy | sed 's|^store=.*|store=|; s|^vtype=.*|vtype=|; s|^hardlink=.*|hardlink=no|')")"
assert_contains "$verdict" "did not answer" "says pnpm could not be asked"
assert_not_contains "$verdict" "virtual store" \
  "and does not pile on the findings that follow from it"
assert_not_contains "$verdict" "hardlink" \
  "nor the hardlink probe that could not have succeeded either"

# Every fault at once, which is what a sandbox created before any of this
# existed actually looks like. Reported together rather than one per re-run:
# the launcher dies on the first call, so a verdict that stopped at the first
# fault would need the user to fix and re-run once per fault to see them all.
verdict="$(pnpm_isolation_verdict "$(healthy | sed 's|^vtype=.*|vtype=|; s|^hardlink=.*|hardlink=no|; s|^voldev=.*|voldev=|')")"
assert_contains "$verdict" "no /var/lib/pnpm volume" "reports the missing volume"
assert_contains "$verdict" "virtual store" "reports the virtual store fault alongside it"
assert_contains "$verdict" "hardlinked" "and the unusable store alongside both"

# --- the probe ---------------------------------------------------------------

# A directory holding stub `pnpm` and `stat`, first on PATH. The probe runs in
# the container against the real ones; here it runs against stubs so the
# gathering can be tested on a machine with neither a pnpm nor a GNU stat.
#
# `stat` is stubbed too because macOS ships the BSD one, which has no -c: the
# probe's own `|| printf ''` would swallow that and report empty device numbers
# on every run, so a real stat here would make the test pass for the wrong
# reason.
stub_dir() {
  # $1 store-dir answer, $2 virtual-store-type answer, $3 device number to
  # report for every path
  local d
  d="$(new_scratch)/bin"
  mkdir -p "$d"
  cat > "$d/pnpm" <<EOF
#!/bin/sh
# Answers \`pnpm config get <key>\`, which is the only call the probe makes.
case "\$3" in
  store-dir)          printf '%s\n' '$1' ;;
  virtual-store-type) printf '%s\n' '$2' ;;
  *)                  printf 'undefined\n' ;;
esac
EOF
  cat > "$d/stat" <<EOF
#!/bin/sh
printf '%s\n' '$3'
EOF
  chmod +x "$d/pnpm" "$d/stat"
  printf '%s' "$d"
}

# Runs the probe with the stubs in front of PATH and a workspace of its own.
probe() {
  # $1 stub directory, $2 workspace directory
  ( PATH="$1:$PATH"; WORKSPACE_DIR="$2"; export WORKSPACE_DIR
    sh -c "$PNPM_ISOLATION_PROBE_SH" )
}

ws="$(new_scratch)/workspace"
mkdir -p "$ws"
store="$(new_scratch)/store"

out="$(probe "$(stub_dir "$store" global 65168)" "$ws")"
assert_contains "$out" "store=$store" "the probe reports the store pnpm resolved"
assert_contains "$out" "vtype=global" "and the virtual store type"
assert_contains "$out" "workspace=$ws" "and the workspace it asked from"
assert_contains "$out" "hardlink=yes" "and that it could hardlink in the store"

# The two the verdict needs to tell a real volume from a missing one and from a
# plain directory. Both come from the stub here, so this only proves the probe
# reports them; that they mean what the verdict thinks is measured against real
# sandboxes and recorded above.
assert_contains "$out" "voldev=" "reports the volume's device"
assert_contains "$out" "rootdev=" "and the container filesystem's, to compare it against"

# The store does not exist until the first install, and the hardlink probe has
# to write inside it. Creating it is the probe's job; reporting it missing
# would fail every sandbox that has not installed anything yet, which is every
# freshly created one.
store_made=no
[[ -d "$store" ]] && store_made=yes
assert_equals yes "$store_made" \
  "the probe creates the store directory rather than reporting it missing"

# `undefined` is what pnpm prints for a setting the running version does not
# have, and passing it through verbatim would make the verdict compare against
# a literal string that means the opposite of a value.
out="$(probe "$(stub_dir "$store" undefined 65168)" "$ws")"
assert_contains "$out" "vtype=
" "undefined is reported as no value at all"

# The probe must leave nothing behind. It runs at every attach, and a store
# accumulating one directory per attach is litter in the one place pnpm
# addresses by content.
out="$(probe "$(stub_dir "$store" global 65168)" "$ws")"
leftovers="$(find "$store" -name '.isolation-probe*' 2>/dev/null)"
assert_equals "" "$leftovers" "the probe removes its own scratch directory"

# A store that cannot be created at all, which is what an unwritable volume
# looks like. The probe has to report that rather than abort: it runs under the
# container's sh with no set -e, and a probe that died here would give the
# launcher nothing to diagnose from.
out="$(probe "$(stub_dir /proc/nonexistent/store global 65168)" "$ws")"
assert_contains "$out" "hardlink=no" "an unwritable store reports no hardlink"
assert_contains "$out" "store=/proc/nonexistent/store" \
  "and still reports the path it was asked to use"

# --- the half the launcher cannot do -----------------------------------------

# The launcher above only covers a sandbox reached through it. A sandbox opened
# with `sbx run` gets no preflight at all, so the kit carries the same finding
# to the agent. It cannot refuse: the startup command must exit 0 or it stops
# the whole chain and takes the other kits' startup commands with it, which is
# the reason the failure was silent to begin with.
spec="$(cat "$REPO_DIR/dev-tools-kit/spec.yaml")"
startup="$(sed -n '/^  startup:/,$p' "$REPO_DIR/dev-tools-kit/spec.yaml")"

assert_contains "$startup" "trap 'exit 0' EXIT" \
  "the startup command still cannot take the chain down with it"

# The three faults it detects. Each is a way the guarantee is absent while
# nothing reports it, which is the whole subject.
# The needle is literal shell text to search for, not text to expand.
# shellcheck disable=SC2016
assert_contains "$startup" 'fault="there is no /var/lib/pnpm volume in this sandbox"' \
  "notices a volume that is not there at all"

# The comparison that catches a sandbox created before the volume was declared.
# It has to be against the container filesystem, not the workspace: the mkdir
# above makes the path either way, and a plain directory there differs from the
# virtiofs workspace, so a workspace comparison passes for exactly the sandbox
# it is meant to reject. Confirmed by building a kit with the volumes block
# removed and starting a sandbox from it: the workspace comparison saw nothing
# wrong, and the launcher had to catch it alone.
# shellcheck disable=SC2016
assert_contains "$startup" '[ "$voldev" = "$rootdev" ]' \
  "notices a volume path that is really a directory on the container filesystem"
assert_contains "$startup" 'store_is_usable' \
  "notices a store it cannot write and hardlink in"

# Written into the file the workspace CLAUDE.md already points the agent at,
# rather than a log nobody opens.
assert_contains "$startup" 'kits-agent-context/dev-tools.md' \
  "records the finding where the agent is already told to look"

# Between markers, and rewritten rather than appended. This runs on every
# container start: appending would stack a block per start, and a fault that
# cleared has to take its warning away with it. Both behaviours are verified
# against a live sandbox; these assertions are what stop the mechanism being
# swapped for a plain append later.
assert_contains "$startup" 'begin="<!-- dev-tools: isolation status -->"' \
  "wraps the block in a marker it can find again"
# shellcheck disable=SC2016
assert_contains "$startup" 'if [ "$line" = "$begin" ]; then skip=1; continue; fi' \
  "strips the previous start's block instead of stacking another"
# shellcheck disable=SC2016
assert_contains "$startup" 'mv "$tmp" "$ctx"' \
  "renames into place, so the agent never reads a half-written file"

# --- the cold install the agent must not investigate --------------------------

# Measured 5 of 5 on the workspace mount and 0 of 5 off it, with every retry
# succeeding. Nothing here can fix it, so the only useful move is telling the
# agent before it spends a session on the filesystem, which is what happened.
# Backticks here are markdown code spans in the text being searched for.
# shellcheck disable=SC2016
assert_contains "$spec" 'The first `pnpm install` on a checkout fails. Run it again.' \
  "the agent is told the first install fails"
assert_contains "$spec" 'ENOTDIR' "and which error to expect"
assert_contains "$spec" 'Retry once, then carry on' "and what to do about it"
