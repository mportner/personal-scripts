#
# File:    resolve_subscription_type_test.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Tests for resolve_subscription_type() in lib/sandbox-launcher.sh, the host
# side of the plan-name fix: it decides which subscriptionType the launchers
# hand the sandbox, and the kit's startup command writes it into the credential
# file there. Sourced by test/run.sh.

PROG=personal-scripts-tests
DRY_RUN=0
# shellcheck source=../lib/output.sh
source "$REPO_DIR/lib/output.sh"
# shellcheck source=../lib/sandbox-launcher.sh
source "$REPO_DIR/lib/sandbox-launcher.sh"

# A host home whose ~/.claude.json carries $1 as oauthAccount.organizationType.
# "-" writes the key as null, and any other content is written verbatim so a
# caller can hand it something that is not JSON.
make_host_home() {
  local home
  home="$(new_scratch)"
  case "${1-}" in
    '')  ;;
    -)   printf '{"oauthAccount":{"organizationType":null}}' > "$home/.claude.json" ;;
    '{'*|'not '*) printf '%s' "$1" > "$home/.claude.json" ;;
    *)   printf '{"oauthAccount":{"organizationType":"%s"}}' "$1" > "$home/.claude.json" ;;
  esac
  printf '%s' "$home"
}

# Resolution reads the environment and $HOME, so each case runs in its own
# subshell and reports through stdout rather than leaking globals into the next.
# The call's own output is discarded: note() writes its diagnostics to stdout,
# which would otherwise land in the result being asserted on.
resolve() {
  # $1 home, $2 value of SBX_CLAUDE_SUBSCRIPTION_TYPE (unset when absent)
  (
    HOME="$1"
    if [[ $# -ge 2 ]]; then export SBX_CLAUDE_SUBSCRIPTION_TYPE="$2"; else unset SBX_CLAUDE_SUBSCRIPTION_TYPE; fi
    SUBSCRIPTION_TYPE=""
    SUBSCRIPTION_TYPE_SOURCE=""
    resolve_subscription_type >/dev/null 2>&1
    printf '%s|%s' "$SUBSCRIPTION_TYPE" "$SUBSCRIPTION_TYPE_SOURCE"
  )
}

# --- the environment wins ----------------------------------------------------

home="$(make_host_home claude_max)"
assert_equals 'pro|SBX_CLAUDE_SUBSCRIPTION_TYPE' "$(resolve "$home" pro)" \
  "an explicit type wins over the host account"

# --- otherwise it is read off the host account -------------------------------

assert_equals 'max|~/.claude.json' "$(resolve "$home")" \
  "derives max from claude_max"

home="$(make_host_home claude_pro)"
assert_equals 'pro|~/.claude.json' "$(resolve "$home")" "derives pro from claude_pro"

home="$(make_host_home enterprise)"
assert_equals 'enterprise|~/.claude.json' "$(resolve "$home")" \
  "passes a type with no claude_ prefix through"

# --- nothing to read ---------------------------------------------------------

home="$(make_host_home)"
assert_equals '|' "$(resolve "$home")" "resolves to nothing with no ~/.claude.json"

home="$(make_host_home -)"
assert_equals '|' "$(resolve "$home")" "resolves to nothing when the account has no type"

home="$(make_host_home 'not json at all')"
assert_equals '|' "$(resolve "$home")" "resolves to nothing from an unparseable ~/.claude.json"

home="$(make_host_home '{"other":true}')"
assert_equals '|' "$(resolve "$home")" "resolves to nothing when there is no oauth account"

# --- a value that is not a plan name is refused, not guessed around ----------

home="$(make_host_home claude_max)"
assert_equals '|' "$(resolve "$home" 'max","accessToken":"stolen')" \
  "refuses a malformed explicit type"
assert_equals '|' "$(resolve "$home" 'MAX')" "refuses an explicit type that is not lower case"

home="$(make_host_home 'claude_Max Plan')"
assert_equals '|' "$(resolve "$home")" "refuses a malformed type from the host account"

# --- a filter it cannot run refuses the value rather than passing it ---------

# jq reachable, tr held back. An unreachable filter returns the empty string,
# which is what a valid plan name returns too, so the check has to notice the
# filter itself failed rather than read that as "nothing to object to".
stub="$(new_scratch)/bin"
mkdir -p "$stub"
for tool in jq printf; do
  tool_path="$(command -v "$tool")" && ln -s "$tool_path" "$stub/$tool"
done
home="$(make_host_home claude_max)"
assert_equals '|' "$(PATH="$stub" resolve "$home")" "refuses a plan the filter could not check"
