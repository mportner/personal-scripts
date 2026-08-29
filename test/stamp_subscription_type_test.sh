#
# File:    stamp_subscription_type_test.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Tests for claude-config-kit's stamp-subscription-type.sh, the startup command
# that writes subscriptionType into the OAuth credential file sbx stages in the
# sandbox. sbx's template omits the field, which makes Claude Code label a
# subscription session "Claude API". Sourced by test/run.sh.
#
# The tokens in these fixtures are the proxy's fixed placeholders, byte for byte
# what sbx puts in the container; the real credential never leaves the host.

SCRIPT="$REPO_DIR/claude-config-kit/files/home/.claude-config-kit/stamp-subscription-type.sh"

CRED='{"claudeAiOauth":{"accessToken":"sk-ant-oat01-proxy-managed","refreshToken":"sk-ant-ort01-proxy-managed","expiresAt":1787985139324,"scopes":["user:inference","user:profile"]}}'

# A container home with a staged credential file. Prints the home; $1 overrides
# the file's contents.
make_home() {
  local home
  home="$(new_scratch)"
  mkdir -p "$home/.claude"
  printf '%s' "${1-$CRED}" > "$home/.claude/.credentials.json"
  chmod 600 "$home/.claude/.credentials.json"
  printf '%s' "$home"
}

# Always through `sh`, the interpreter the kit's startup command uses.
run_stamp() {
  HOME="$1" SBX_CLAUDE_SUBSCRIPTION_TYPE="${2-max}" sh "$SCRIPT" 2>"$1/stderr"
}

field() {
  # $1 home, $2 jq path
  jq -r "$2" "$1/.claude/.credentials.json"
}

# --- the field is added, and nothing else changes ----------------------------

home="$(make_home)"
run_stamp "$home"
assert_equals 0 $? "exits 0 on a staged credential file"
assert_equals 'max' "$(field "$home" '.claudeAiOauth.subscriptionType')" "writes the type"
assert_equals 'sk-ant-oat01-proxy-managed' "$(field "$home" '.claudeAiOauth.accessToken')" \
  "leaves the access token alone"
assert_equals '2' "$(field "$home" '.claudeAiOauth.scopes | length')" "leaves the scopes alone"
assert_equals '1787985139324' "$(field "$home" '.claudeAiOauth.expiresAt')" \
  "keeps expiresAt a number"
assert_file_mode 600 "$home/.claude/.credentials.json" "keeps the file mode at 600"

leftovers="$(ls -A "$home/.claude")"
assert_equals '.credentials.json' "$leftovers" "leaves no temp files beside the target"

# --- idempotent, and never overwrites a type that is already there -----------

before="$(cat "$home/.claude/.credentials.json")"
run_stamp "$home"
assert_equals 0 $? "exits 0 on an already stamped file"
assert_equals "$before" "$(cat "$home/.claude/.credentials.json")" "is idempotent"

home="$(make_home '{"claudeAiOauth":{"accessToken":"x","subscriptionType":"pro"}}')"
run_stamp "$home" max
assert_equals 'pro' "$(field "$home" '.claudeAiOauth.subscriptionType')" \
  "does not overwrite a type the file already carries"

# --- nothing to do -----------------------------------------------------------

home="$(make_home)"
HOME="$home" sh "$SCRIPT" >/dev/null 2>&1
assert_equals 0 $? "exits 0 with no type in the environment"
assert_equals 'null' "$(field "$home" '.claudeAiOauth.subscriptionType')" \
  "writes nothing when no type is set"

home="$(new_scratch)"
mkdir -p "$home/.claude"
run_stamp "$home"
assert_equals 0 $? "exits 0 when there is no credential file"
[[ -e "$home/.claude/.credentials.json" ]] && fail "creates a credential file that was not there"

# --- files it does not understand are left exactly as they are ---------------

home="$(make_home 'not json at all')"
run_stamp "$home"
assert_equals 0 $? "exits 0 on an unparseable file"
assert_equals 'not json at all' "$(cat "$home/.claude/.credentials.json")" \
  "leaves an unparseable file untouched"
assert_contains "$(cat "$home/stderr")" 'claude-config' "says why it did nothing"

home="$(make_home '{"anthropicApiKey":"sk-ant-api03-x"}')"
run_stamp "$home"
assert_equals 0 $? "exits 0 on a file with no OAuth entry"
assert_equals '{"anthropicApiKey":"sk-ant-api03-x"}' "$(cat "$home/.claude/.credentials.json")" \
  "leaves an API key credential untouched"

# --- a value that is not a plan name is refused ------------------------------

home="$(make_home)"
run_stamp "$home" 'max","accessToken":"stolen'
assert_equals 0 $? "exits 0 on a malformed type"
assert_equals "$CRED" "$(cat "$home/.claude/.credentials.json")" "refuses a malformed type"
assert_contains "$(cat "$home/stderr")" 'claude-config' "says why it refused"

# --- without jq it does nothing rather than guessing --------------------------

# A PATH holding every command the script runs BEFORE the jq check, and nothing
# else. Leaving one out would make this case "jq and that command are missing",
# which passes for the wrong reason: the plan-name filter would not run either,
# and the test would no longer isolate what it is named for.
make_stub_path() {
  # $@ the commands to make reachable
  local stub tool path
  stub="$(new_scratch)/bin"
  mkdir -p "$stub"
  for tool in "$@"; do
    path="$(command -v "$tool")" && ln -s "$path" "$stub/$tool"
  done
  printf '%s' "$stub"
}

home="$(make_home)"
stub="$(make_stub_path sh tr mv rm chmod cat)"
( PATH="$stub" HOME="$home" SBX_CLAUDE_SUBSCRIPTION_TYPE=max sh "$SCRIPT" >/dev/null 2>&1 )
assert_equals 0 $? "exits 0 when jq is not installed"
assert_equals "$CRED" "$(cat "$home/.claude/.credentials.json")" "leaves the file alone without jq"

# --- a filter it cannot run refuses the value rather than passing it ---------

# tr held back, jq reachable. An unreachable filter returns the empty string,
# which is what a valid plan name returns too, so the check has to notice the
# filter itself failed rather than read that as "nothing to object to".
home="$(make_home)"
stub="$(make_stub_path sh jq mv rm chmod cat)"
( PATH="$stub" HOME="$home" SBX_CLAUDE_SUBSCRIPTION_TYPE=max sh "$SCRIPT" >/dev/null 2>&1 )
assert_equals 0 $? "exits 0 when the filter cannot run"
assert_equals "$CRED" "$(cat "$home/.claude/.credentials.json")" \
  "stamps nothing when the filter cannot run"

# An upper-case spelling is refused too. A [!a-z0-9_] glob would accept it: in a
# UTF-8 locale that range collates case-insensitively.
home="$(make_home)"
run_stamp "$home" MAX
assert_equals 0 $? "exits 0 on an upper-case type"
assert_equals "$CRED" "$(cat "$home/.claude/.credentials.json")" "refuses an upper-case type"
