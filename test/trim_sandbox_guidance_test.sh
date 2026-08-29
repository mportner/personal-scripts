#
# File:    trim_sandbox_guidance_test.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Tests for claude-config-kit's trim-sandbox-guidance.sh, the startup command
# that rewrites the CLAUDE.md sbx generates one directory above the workspace.
#
# The fixture beside this file is a condensed copy of the real generated file
# (sbx 0.39.0): same H1, same generated project-guidance sections, the same
# `## Environment Persistence` anchor where sbx's own content starts, and the
# same sentinel-wrapped `## Kits` section at the end. It deliberately carries no
# file header: the script keys off its first line being `# Project Guidance`, so
# a header would make the fixture a file the script is meant to refuse rather
# than the one it is meant to rewrite. Sourced by test/run.sh.

SCRIPT="$REPO_DIR/claude-config-kit/files/home/.claude-config-kit/trim-sandbox-guidance.sh"
FIXTURE="$TEST_DIR/fixtures/generated-guidance.md"

# A sandbox layout: <root>/CLAUDE.md generated above <root>/ws, the workspace.
# Prints the root; the caller reads $root/CLAUDE.md. Content defaults to the
# fixture, and $1 overrides it with a file of the caller's own.
make_sandbox() {
  local root src
  root="$(new_scratch)"
  src="${1:-$FIXTURE}"
  mkdir -p "$root/ws"
  printf '# Project pnpm rules\n' > "$root/ws/CLAUDE.md"
  cp "$src" "$root/CLAUDE.md"
  printf '%s' "$root"
}

# Always through `sh`, the interpreter the kit's startup command uses.
run_trim() {
  WORKSPACE_DIR="$1/ws" sh "$SCRIPT" 2>"$1/stderr"
}

# --- the generated project guidance goes away -------------------------------

root="$(make_sandbox)"
run_trim "$root"
status=$?
out="$(cat "$root/CLAUDE.md")"

assert_equals 0 "$status" "exits 0 on a generated file"
assert_not_contains "$out" '## Tools and Commands' "drops the generated command section"
assert_not_contains "$out" 'npm install' "drops the npm instructions"
assert_not_contains "$out" '## Project Overview' "drops the generated overview"
assert_not_contains "$out" '## Coding Style' "drops the generated style section"
assert_not_contains "$out" '## Testing Approach' "drops the generated testing section"

# --- everything sbx actually knows survives ---------------------------------

assert_contains "$out" '## Environment Persistence' "keeps the environment section"
assert_contains "$out" '## Network access' "keeps the network section"
assert_contains "$out" '## Git Authentication' "keeps the git auth section"
assert_contains "$out" '## Git workspace mode' "keeps the workspace mode section"
assert_contains "$out" '## Claude Code: Environment Persistence' "keeps the trailing claude section"
assert_contains "$out" '<!-- sbx:kits-section start -->' "keeps the kits sentinel"
assert_contains "$out" 'claude-research.md' "keeps the kits pointer"

# --- the replacement header defers to the project ---------------------------

assert_contains "$out" '# Sandbox Guidance' "writes its own heading"
assert_contains "$out" 'workspace' "the header talks about the workspace"
first_line="$(head -1 "$root/CLAUDE.md")"
assert_contains "$first_line" 'claude-config-kit' "marks the file on the first line"

# --- the generic Additional Notes block goes too -----------------------------

assert_not_contains "$out" '## Additional Notes

- Always read relevant files' "drops the generic notes section"
assert_not_contains "$out" 'npm, pip and uv are already available' "drops the notes npm line"

# --- a fenced line that looks like a heading is not one ----------------------

assert_contains "$out" '# A fenced block whose contents must not be read as headings.' \
  "keeps the fenced block"
assert_contains "$out" 'echo "export VAR_NAME=value"' "keeps the line after the fenced heading"

# --- the dropped section never swallows sbx's own sentinel -------------------

# The real file has another heading between the two. This is the shape that
# arrives if sbx ever stops putting one there: the opening sentinel must survive
# so its pair stays balanced.
adjacent="$(new_scratch)/adjacent.md"
{
  printf '# Project Guidance\n\n## Tools and Commands\n\n- Use "npm install"\n\n'
  printf '## Environment Persistence\n\nA sandbox fact.\n\n'
  printf '## Additional Notes\n\n- Generic advice nobody wrote about this project\n\n'
  printf '<!-- sbx:kits-section start -->\n## Kits\n\n- A kit pointer.\n'
  printf '<!-- sbx:kits-section end -->\n'
} > "$adjacent"
root="$(make_sandbox "$adjacent")"
run_trim "$root"
out="$(cat "$root/CLAUDE.md")"
assert_contains "$out" '<!-- sbx:kits-section start -->' "keeps the opening sentinel"
assert_contains "$out" '<!-- sbx:kits-section end -->' "keeps the closing sentinel"
assert_contains "$out" '## Kits' "keeps the kits heading"
assert_not_contains "$out" 'Generic advice nobody wrote' "still drops the notes section"

# --- the workspace's own file is never touched -------------------------------

assert_equals '# Project pnpm rules' "$(cat "$root/ws/CLAUDE.md")" \
  "leaves the workspace's own CLAUDE.md alone"

# --- no temp files left behind -----------------------------------------------

# With no matches the glob stays unexpanded, so comparing it against itself is
# the assertion that nothing matched.
leftovers=("$root"/CLAUDE.md.*)
assert_equals "$root/CLAUDE.md.*" "${leftovers[0]}" "leaves no temp files beside the target"

# --- running twice changes nothing -------------------------------------------

before="$(cat "$root/CLAUDE.md")"
run_trim "$root"
assert_equals 0 $? "exits 0 on an already trimmed file"
assert_equals "$before" "$(cat "$root/CLAUDE.md")" "is idempotent"

# --- a file it does not recognise is left alone ------------------------------

other="$(new_scratch)/other.md"
printf '# Someone else wrote this\n\nWith no anchor in it.\n' > "$other"
root="$(make_sandbox "$other")"
run_trim "$root"
assert_equals 0 $? "exits 0 on a file it does not recognise"
assert_equals "$(cat "$other")" "$(cat "$root/CLAUDE.md")" "leaves an unrecognised file untouched"

# --- a generated file with no anchor is left alone ---------------------------

noanchor="$(new_scratch)/noanchor.md"
printf '# Project Guidance\n\n## Tools and Commands\n\n- Use "npm install"\n' > "$noanchor"
root="$(make_sandbox "$noanchor")"
run_trim "$root"
assert_equals 0 $? "exits 0 when the anchor is missing"
assert_equals "$(cat "$noanchor")" "$(cat "$root/CLAUDE.md")" "leaves a file with no anchor untouched"
assert_contains "$(cat "$root/stderr")" 'claude-config' "says why it did nothing"

# --- nothing above the workspace at all --------------------------------------

root="$(new_scratch)"
mkdir -p "$root/ws"
run_trim "$root"
assert_equals 0 $? "exits 0 when there is no generated file"
[[ -e "$root/CLAUDE.md" ]] && fail "creates a file that was not there"

# --- no WORKSPACE_DIR in the environment -------------------------------------

( unset WORKSPACE_DIR; sh "$SCRIPT" >/dev/null 2>&1 )
assert_equals 0 $? "exits 0 with no WORKSPACE_DIR set"
