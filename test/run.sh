#!/usr/bin/env bash
#
# File:    run.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Runs every test/*_test.sh file and reports pass or fail per file.
#
# A plain bash runner rather than bats: the repo already targets bash 3.2 with
# no interpreter to install, and adding a test framework as a dependency would
# undo that for the one thing that has to run on a stock machine and in CI.
#
# Each test file is run in its own subshell with TEST_TMPDIR pointing at a
# scratch directory of its own, and is expected to leave TEST_FAILURES at 0.
# Targets bash 3.2, the version macOS ships.
set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "$TEST_DIR/.." && pwd -P)"
export TEST_DIR REPO_DIR

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/personal-scripts-tests.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

files=()
if (( $# )); then
  files=("$@")
else
  for f in "$TEST_DIR"/*_test.sh; do
    [[ -e "$f" ]] || continue
    files+=("$f")
  done
fi

(( ${#files[@]} )) || { printf 'no test files found in %s\n' "$TEST_DIR" >&2; exit 1; }

passed=0
failed=0

for f in "${files[@]}"; do
  name="$(basename -- "$f")"
  printf '%s\n' "$name"

  # Subshell, so a test file cannot leak state (cd, variables, traps) into the
  # next one. The failure count is read back through the exit status rather
  # than a shared file: a test file that dies partway through then still
  # counts as a failure instead of silently reporting the last count written.
  if (
    TEST_TMPDIR="$(mktemp -d "$TMP_ROOT/$name.XXXXXX")"
    export TEST_TMPDIR
    # shellcheck source=lib-assert.sh
    source "$TEST_DIR/lib-assert.sh"
    # shellcheck source=/dev/null
    source "$f"
    exit $(( TEST_FAILURES > 0 ))
  ); then
    printf '  ok\n'
    passed=$((passed + 1))
  else
    printf '  FAILED\n'
    failed=$((failed + 1))
  fi
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
