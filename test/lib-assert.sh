#
# File:    lib-assert.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Assertions, per-test scratch directories and shared fixtures for test/run.sh.
# Sourced by every *_test.sh file, never executed on its own.
#
# Each assertion prints a one-line diagnosis and marks the current test failed
# rather than aborting, so one test reports every way it is wrong in a single
# run instead of one failure per re-run.

# Set by run.sh for each test file; assertions bump it.
TEST_FAILURES=0

fail() {
  TEST_FAILURES=$((TEST_FAILURES + 1))
  printf '    FAIL  %s\n' "$1" >&2
}

assert_equals() {
  # $1 expected, $2 actual, $3 what
  if [[ "$1" != "$2" ]]; then
    fail "$3"
    printf '          expected: %s\n' "$1" >&2
    printf '          actual:   %s\n' "$2" >&2
  fi
}

assert_contains() {
  # $1 haystack, $2 needle, $3 what
  case "$1" in
    *"$2"*) ;;
    *)
      fail "$3"
      printf '          expected to contain: %s\n' "$2" >&2
      ;;
  esac
}

assert_not_contains() {
  # $1 haystack, $2 needle, $3 what
  case "$1" in
    *"$2"*)
      fail "$3"
      printf '          expected NOT to contain: %s\n' "$2" >&2
      ;;
  esac
}

assert_file_mode() {
  # $1 expected mode (e.g. 600), $2 path, $3 what
  local mode
  # GNU first, BSD second. The other order is not safe: GNU's -f means
  # --file-system and succeeds with an unrelated answer rather than failing,
  # while BSD's stat has no -c at all and errors out cleanly.
  mode="$(stat -c '%a' "$2" 2>/dev/null || stat -f '%OLp' "$2" 2>/dev/null)"
  assert_equals "$1" "$mode" "$3"
}

# A scratch directory per call, removed when the test file finishes. Kept under
# the runner's own temp root so a crashed test leaves everything in one place.
new_scratch() {
  mktemp -d "$TEST_TMPDIR/case.XXXXXX"
}

# A checkout with a github origin, which is what the launchers derive the owner
# from, and whose directory name is what project-sandbox names the sandbox
# after. Shared by the launcher wiring tests, which both need one and had the
# same fixture twice.
make_checkout() {
  local dir
  dir="$(new_scratch)/checkout"
  mkdir -p "$dir"
  # An explicit default branch keeps git from printing its init.defaultBranch
  # advice into the middle of the test output.
  git -C "$dir" -c init.defaultBranch=main init -q
  git -C "$dir" remote add origin https://github.com/mportner/example.git
  printf 'x\n' > "$dir/a.txt"
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@example.com -c user.name=t commit -qm init
  printf '%s' "$dir"
}
