#
# File:    launcher_plan_wiring_test.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Checks that both launchers resolve the plan name and hand it to `sbx create`.
# The unit tests either side of this cover the resolution and what the sandbox
# does with the value; what is left is the wiring between them, which only a run
# of the launcher itself exercises. Sourced by test/run.sh.
#
# Every run is a --dry-run against a stub PATH, so nothing here creates a
# sandbox, clones a repository or reaches the network.

PROJECT="$REPO_DIR/bin/project-sandbox.sh"
RESEARCH="$REPO_DIR/bin/research-sandbox.sh"

# gh and sbx are stubbed rather than left to the host: the ruleset check would
# otherwise make a real API call, and `sbx secret ls` would read the host's own
# secret store. Both launchers treat a failing gh or sbx as "could not check",
# which is the answer a hermetic test wants.
make_stub_path() {
  local stub
  stub="$(new_scratch)/bin"
  mkdir -p "$stub"
  for tool in gh sbx op; do
    printf '#!/bin/sh\nexit 1\n' > "$stub/$tool"
    chmod +x "$stub/$tool"
  done
  printf '%s' "$stub"
}

# A host home whose account record reports $1 as the organisation type, or no
# record at all when $1 is empty. Named apart from the make_host_home in
# resolve_subscription_type_test.sh, which takes the same first argument but
# also accepts the malformed shapes that test needs.
make_account_home() {
  local home
  home="$(new_scratch)"
  [[ -n "${1-}" ]] && printf '{"oauthAccount":{"organizationType":"%s"}}' "$1" > "$home/.claude.json"
  printf '%s' "$home"
}

run_project() {
  # $1 host home, $2 checkout
  (
    cd "$2" || exit 1
    PATH="$(make_stub_path):$PATH" HOME="$1" SBX_DEV_STATE_ROOT="$1/state" \
      "$PROJECT" --dry-run -y --no-token 2>&1
  )
}

run_research() {
  # $1 host home
  (
    PATH="$(make_stub_path):$PATH" HOME="$1" RESEARCH_SEED_ROOT="$1/seeds" \
      "$RESEARCH" --dry-run --no-token mportner/example 2>&1
  )
}

# --- the plan reaches sbx create ---------------------------------------------

home="$(make_account_home claude_pro)"
out="$(run_project "$home" "$(make_checkout)")"
assert_contains "$out" 'plan      pro, read from ~/.claude.json' "project-sandbox reports the plan"
assert_contains "$out" '-e SBX_CLAUDE_SUBSCRIPTION_TYPE=pro' "project-sandbox passes the plan to create"

out="$(run_research "$home")"
assert_contains "$out" 'plan      pro, read from ~/.claude.json' "research-sandbox reports the plan"
assert_contains "$out" '-e SBX_CLAUDE_SUBSCRIPTION_TYPE=pro' "research-sandbox passes the plan to create"

# --- an explicit plan wins ---------------------------------------------------

out="$(SBX_CLAUDE_SUBSCRIPTION_TYPE=max run_project "$home" "$(make_checkout)")"
assert_contains "$out" '-e SBX_CLAUDE_SUBSCRIPTION_TYPE=max' "an explicit plan reaches create"

# --- with no plan, nothing is passed at all ----------------------------------

# The create line alone, not the whole run: the note about an undetected plan
# names the variable itself, so the assertion has to look where the argument
# would be rather than anywhere in the output.
create_line() { printf '%s\n' "$1" | grep 'would run: sbx create'; }

home="$(make_account_home)"
out="$(run_project "$home" "$(make_checkout)")"
assert_contains "$out" "the sandbox banner will read 'Claude API'" "says the banner will be wrong"
assert_contains "$out" 'would run: sbx create' "still reports the create it would run"
assert_not_contains "$(create_line "$out")" 'SBX_CLAUDE_SUBSCRIPTION_TYPE' \
  "passes no empty variable to create"

out="$(run_research "$home")"
assert_contains "$out" 'would run: sbx create' "research-sandbox still reports the create"
assert_not_contains "$(create_line "$out")" 'SBX_CLAUDE_SUBSCRIPTION_TYPE' \
  "research-sandbox passes no empty variable"
