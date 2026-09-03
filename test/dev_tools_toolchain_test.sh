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

# --- the volume ---------------------------------------------------------------

assert_contains "$spec" 'path: /var/lib/pnpm' "declares the pnpm volume"

# Without a size sbx hands back a 488M volume, which ENOSPCs partway through a
# real install. This is the field whose absence was the reason the kit avoided
# volumes altogether.
volume_block="$(sed -n '/^volumes:/,/^environment:/p' "$SPEC")"
assert_contains "$volume_block" 'size:' "gives the volume an explicit size"

# --- pnpm pointed at it -------------------------------------------------------

# pnpm 11 reads pnpm_config_* / PNPM_CONFIG_*. The npm_config_* spelling is
# accepted by nothing and fails silently, leaving the store at its default.
env_block="$(sed -n '/^environment:/,/^setup:/p' "$SPEC")"
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
assert_contains "$spec" 'PNPM_CONFIG_VIRTUAL_STORE_TYPE: global' \
  "keeps the virtual store off the workspace mount"

# --- the volume is writable ---------------------------------------------------

startup="$(sed -n '/^  startup:/,$p' "$SPEC")"
assert_contains "$startup" 'chown -R agent:agent /var/lib/pnpm' \
  "hands the root-owned volume to the agent"
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

# `packageManager` makes pnpm 11 self-manage: a pnpm that is not the pinned
# version fetches one from the npm registry as @pnpm/exe and re-executes it.
# That copy ships a placeholder binary needing a lifecycle script, and when the
# script does not run every pnpm call in the project fails. It does not trigger
# when the running pnpm already matches the pin, which is the whole reason mise
# is here, so these are the settings that keep it from coming back.

MISE_CONF="$REPO_DIR/dev-tools-kit/files/home/.config/mise/config.toml"
mise_conf="$(cat "$MISE_CONF")"

assert_contains "$mise_conf" 'idiomatic_version_file_enable_tools = ["pnpm"]' \
  "reads each project's pnpm pin from its package.json"
assert_contains "$mise_conf" 'pnpm = ' "declares a baseline pnpm for outside a project"
assert_contains "$mise_conf" 'node = ' "declares a baseline node"

# The baseline has to clear 11.23, the release that added virtualStoreType.
# Below it the setting above is ignored and the virtual store stays in the tree.
baseline="$(printf '%s\n' "$mise_conf" | sed -n 's/^pnpm = "\([^"]*\)".*/\1/p')"
baseline_minor="$(printf '%s\n' "$baseline" | cut -d. -f2)"
if [[ "$(printf '%s\n' "$baseline" | cut -d. -f1)" != 11 || "$baseline_minor" -lt 23 ]]; then
  fail "baseline pnpm $baseline predates virtualStoreType (needs 11.23+)"
fi

# mise is pinned and checksum-verified like every other direct download here.
assert_contains "$spec" 'MISE_VERSION=' "pins the mise version"
assert_contains "$spec" 'SHASUMS256.txt' "verifies mise against its published manifest"

# The hand-rolled installs it replaced. Either one coming back would put a
# second, unverified pnpm on PATH alongside the mise shim.
assert_not_contains "$spec" 'PNPM_SHA256' "no longer pins a pnpm tarball by hand"
assert_not_contains "$spec" '/usr/local/lib/pnpm' "no longer unpacks pnpm itself"
