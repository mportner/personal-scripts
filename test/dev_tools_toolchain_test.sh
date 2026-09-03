#
# File:    dev_tools_toolchain_test.sh
# Created: 2026-09-03
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Tests dev-tools-kit's toolchain: where pnpm writes, and which pnpm runs.
#
# The workspace is a virtiofs mount of the host checkout, so a pnpm install
# that writes under it writes a Linux install into a macOS tree. The kit used
# to prevent that by bind-mounting a private directory over every node_modules
# at container start, which failed silently and could not cover a worktree
# created afterwards. It now declares a sized volume and points pnpm at it.
#
# These assertions are what stop that reverting quietly: each one is a setting
# whose absence brings the old failure back without any error being raised.
# Sourced by test/run.sh.

SPEC="$REPO_DIR/dev-tools-kit/spec.yaml"
spec="$(cat "$SPEC")"

# One top-level block of the spec, so an assertion can be aimed at the section
# where a setting would actually take effect rather than at the whole file,
# where a comment mentioning it would satisfy the match.
# $1 the key the section starts at, $2 the key that ends it
spec_section() {
  sed -n "/^$1:/,/^$2:/p" "$SPEC"
}

# --- the volume ---------------------------------------------------------------

# Both assertions read the volumes block rather than the whole file. This file
# mentions /var/lib/pnpm in prose in several places, so a whole-file match
# stays green when the declaration itself is deleted, which is the one thing
# the assertion exists to catch.
volume_block="$(spec_section volumes environment)"
assert_contains "$volume_block" 'path: /var/lib/pnpm' "declares the pnpm volume"

# Without a size sbx hands back a 488M volume, which ENOSPCs partway through a
# real install. This is the field whose absence was the reason the kit avoided
# volumes altogether.
assert_contains "$volume_block" 'size:' "gives the volume an explicit size"

# --- pnpm pointed at it -------------------------------------------------------

# pnpm 11 reads pnpm_config_* / PNPM_CONFIG_*. The npm_config_* spelling is
# accepted by nothing and fails silently, leaving the store at its default.
env_block="$(spec_section environment setup)"
assert_contains "$env_block" 'PNPM_CONFIG_STORE_DIR: /var/lib/pnpm/store' \
  "points the content-addressable store at the volume"

# Matched against the declared variables rather than the whole file, so the
# comment explaining why this spelling is wrong does not trip the assertion.
declared="$(printf '%s\n' "$env_block" | grep -vE '^[[:space:]]*#' || true)"
assert_not_contains "$declared" 'npm_config_store_dir' \
  "does not declare the npm_config_ spelling, which pnpm 11 ignores"

# The store alone is not enough. Left at its default the virtual store sits in
# <project>/node_modules/.pnpm, on the workspace mount, and pnpm cannot
# hardlink from a store on another filesystem: it copies every package instead.
assert_contains "$declared" 'PNPM_CONFIG_VIRTUAL_STORE_TYPE: global' \
  "keeps the virtual store off the workspace mount"

# --- the volume is writable ---------------------------------------------------

startup="$(sed -n '/^  startup:/,$p' "$SPEC")"  # nested, so not spec_section
assert_contains "$startup" 'chown -R agent:agent /var/lib/pnpm' \
  "hands the root-owned volume to the agent"

# The recursive pass is guarded on the volume root, so it does not fire when
# only the store directory beneath it went missing and was recreated by root.
# That case needs its own unconditional chown or the agent cannot write its
# store, with nothing to say so.
assert_contains "$startup" 'chown agent:agent /var/lib/pnpm/store' \
  "hands the store directory over even when the volume root is already owned"
assert_contains "$startup" "trap 'exit 0' EXIT" \
  "cannot take the startup chain down with it"

# --- the replaced mechanism is gone -------------------------------------------

# Both copies, the kit's and the launcher's. A leftover mount would stack on
# top of the volume rather than fail, so this is not self-announcing either.
assert_not_contains "$spec" 'mount --bind' \
  "no longer bind-mounts over node_modules"
assert_not_contains "$spec" '/var/lib/sbx-dev-tools' \
  "no longer keeps a backing store on the container overlay"

launcher="$(cat "$REPO_DIR/bin/project-sandbox.sh")"
assert_not_contains "$launcher" 'isolate_worktree_node_modules' \
  "launcher no longer carries its own copy of the isolation"
assert_not_contains "$launcher" 'mount --bind' \
  "launcher no longer mounts anything into the sandbox"

# --- pnpm comes from mise, at the version the project pins --------------------

# `packageManager` makes pnpm 11 fetch a second pnpm from the npm registry and
# re-execute it, and that copy arrives broken. It does not do so when the
# running pnpm already matches the pin, which is the whole reason mise is here.
# See "pnpm: mise, not corepack and not npm" in dev-tools-kit/README.md; these
# are the settings that keep the behaviour from coming back.

MISE_CONF="$REPO_DIR/dev-tools-kit/files/home/.config/mise/config.toml"
mise_conf="$(cat "$MISE_CONF")"

assert_contains "$mise_conf" 'idiomatic_version_file_enable_tools = ["pnpm"]' \
  "reads each project's pnpm pin from its package.json"
assert_contains "$mise_conf" 'pnpm = ' "declares a baseline pnpm for outside a project"
assert_contains "$mise_conf" 'node = ' "declares a baseline node"

# The baseline has to be at least 11.23, the release that added
# virtualStoreType. Below it the setting above is ignored and the virtual store
# stays in the tree, on the workspace mount, while the store has already moved
# to the volume: pnpm then cannot hardlink between them and copies instead.
#
# Compared as major-then-minor rather than pinned to major 11, so a future
# pnpm 12 baseline reads as newer than 11.23 instead of failing this. Both
# components are checked for digits first, because `-lt` on a non-numeric
# string aborts with "integer expression expected" rather than failing the
# assertion this file is here to make.
baseline="$(printf '%s\n' "$mise_conf" | sed -n 's/^pnpm = "\([^"]*\)".*/\1/p')"
baseline_major="${baseline%%.*}"
baseline_rest="${baseline#*.}"
baseline_minor="${baseline_rest%%.*}"
case "$baseline_major:$baseline_minor" in
  *[!0-9:]* | :* | *: )
    fail "baseline pnpm '$baseline' is not a version this test can compare"
    ;;
  *)
    if [[ "$baseline_major" -lt 11 ]] ||
       { [[ "$baseline_major" -eq 11 ]] && [[ "$baseline_minor" -lt 23 ]]; }; then
      fail "baseline pnpm $baseline predates virtualStoreType (needs 11.23+)"
    fi
    ;;
esac

# mise is pinned and checksum-verified like every other direct download here.
assert_contains "$spec" 'MISE_VERSION=' "pins the mise version"
assert_contains "$spec" 'SHASUMS256.txt' "verifies mise against its published manifest"

# The kit README tabulates the same version, and the two drifted apart once
# already: the pin moved to clear the release-age window and the table kept
# advertising the version it replaced, which is exactly the kind of mismatch
# someone debugging the toolchain would trust.
spec_mise="$(printf '%s\n' "$spec" | sed -n 's/^ *MISE_VERSION=v\([^ ]*\).*/\1/p')"
readme_mise="$(sed -n 's/^| mise | \([^ |]*\) .*/\1/p' "$REPO_DIR/dev-tools-kit/README.md")"
assert_equals "$spec_mise" "$readme_mise" "kit README tabulates the pinned mise version"

# The hand-rolled installs it replaced. Either one coming back would put a
# second, unverified pnpm on PATH alongside the mise shim.
assert_not_contains "$spec" 'PNPM_SHA256' "no longer pins a pnpm tarball by hand"
assert_not_contains "$spec" '/usr/local/lib/pnpm' "no longer unpacks pnpm itself"
