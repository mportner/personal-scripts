#!/usr/bin/env bash
#
# File:    setup.sh
# Created: 2026-08-21
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Wires this repo into your shell:
#
#   bin/    executables, symlinked into a directory on PATH so they can be run
#           from anywhere as commands.
#   shell/  fragments that define functions or aliases. These cannot be run as
#           commands at all, so they get a "source" line in the shell rc file
#           instead. Executing one would define its functions in a subprocess
#           that immediately exits, throwing them away. Currently empty: the
#           one fragment that used to live here was the sbx kit wrapper, which
#           bin/project-sandbox.sh replaced.
#
# Safe to re-run: it converges both the link directory and the managed rc block
# on the current contents of bin/ and shell/, and never touches anything it did
# not create.
#
# Targets bash 3.2, the version macOS ships. That means no associative arrays
# and no bare "${arr[@]}" on a possibly-empty array (unbound under set -u).
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_SRC="$REPO_DIR/bin"
SHELL_SRC="$REPO_DIR/shell"
TARGET="${PERSONAL_SCRIPTS_BIN:-$HOME/.local/bin}"
SHELL_RC="${ZDOTDIR:-$HOME}/.zshrc"

# Marker for the block this script manages, so it can be found and rewritten on
# re-run, and removed by uninstall.sh without disturbing the rest of the file.
BLOCK_BEGIN='# personal-scripts'
BLOCK_END='# personal-scripts end'

ASSUME_YES=0
DRY_RUN=0
NO_SANDBOX=0

usage() {
  cat <<'EOF'
Usage: setup.sh [options]

Symlinks each executable in bin/ into ~/.local/bin, with a known script
extension (.sh, .bash, .zsh, .py, .rb, .pl) stripped, so brew-upgrade-safe.sh
becomes the command brew-upgrade-safe.

Adds a managed block to your shell rc file that puts that directory on PATH and
sources every fragment in shell/. Fragments define shell functions, so they must
be sourced rather than executed and are never symlinked onto PATH. There are
none at present, so the block is the PATH stanza alone.

Re-running converges on the current contents of both directories: new scripts
are linked, moved ones are repointed, links to scripts that no longer exist are
pruned, and the rc block is rewritten when it drifts. Regular files and symlinks
pointing outside this repo are never touched.

Options:
  -y, --yes        Skip the confirmation prompt for editing the shell rc file.
  -n, --dry-run    Report what would change and exit without changing anything.
      --no-sandbox Leave out bin/ scripts that declare "# requires: sbx"
                   (the Docker sandboxes CLI). Everything else installs as
                   usual. Re-running without the flag links them back;
                   re-running with it removes them again.
  -h, --help       Show this help.

Environment:
  PERSONAL_SCRIPTS_BIN   Link directory (default ~/.local/bin).
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -y|--yes)     ASSUME_YES=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    --no-sandbox) NO_SANDBOX=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ -d "$BIN_SRC" ]] || { printf 'No bin directory at %s\n' "$BIN_SRC" >&2; exit 1; }

# --- helpers ----------------------------------------------------------------

# Raw (non-recursive) link target. We always create absolute links into
# REPO_DIR, so the raw value is enough to recognise our own, and unlike
# readlink -f it still reports a target that no longer exists.
link_target() { readlink -- "$1" 2>/dev/null || printf ''; }

is_ours() { [[ "$1" == "$REPO_DIR"/* ]]; }

# Octal permissions of a file, falling back to 644.
#
# stat is not portable, and the two spellings cannot simply be chained: GNU
# accepts -c, BSD/macOS accepts -f, but `stat -f` on GNU is not an error, it
# asks about the FILE SYSTEM and exits 0 with output that is not a mode. So
# try GNU first (BSD -c is a genuine usage error) and validate the result
# before handing it to chmod.
file_mode() {
  local mode
  mode="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true)"
  case "$mode" in
    ''|*[!0-7]*) mode=644 ;;
  esac
  printf '%s' "$mode"
}

# brew-upgrade-safe.sh -> brew-upgrade-safe
#
# Only a known script suffix is stripped, not everything after the last dot.
# Cutting at the last dot would install bin/backup.v2 as "backup" and
# bin/foo.2.sh as "foo.2".
command_name() {
  local base="${1##*/}"
  case "$base" in
    *.sh|*.bash|*.zsh|*.py|*.rb|*.pl) printf '%s' "${base%.*}" ;;
    *) printf '%s' "$base" ;;
  esac
}

# The external tool a bin/ script declares it needs, taken from a
# "# requires: sbx" line in its header, or empty when it declares none.
#
# The script naming its own dependency is what keeps this honest. A list of
# sandbox scripts kept here would drift the moment one is added or renamed,
# and the real question is not "is this a sandbox script" but "does this need
# a tool the machine may not have".
#
# Only the header is searched, so the same words further down a script that
# documents this convention do not turn into a requirement. The header ends at
# the first line that is neither a comment nor blank, which beats a line count:
# a count generous enough to be safe today is one a longer preamble outgrows
# silently, dropping the requirement with no signal that it did.
required_tool() {
  awk '/^# requires: / { sub(/^# requires:[ \t]*/, ""); print; exit }
       /^#/ || /^[[:space:]]*$/ { next }
       { exit }' "$1"
}

in_list() {
  local needle="$1" x
  shift
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

# Anything already on PATH under this name, ignoring our own link.
shadowed_by() {
  local name="$1" dir
  local IFS=':'
  for dir in $PATH; do
    [[ -n "$dir" && "$dir" != "$TARGET" ]] || continue
    if [[ -x "$dir/$name" && ! -d "$dir/$name" ]]; then
      printf '%s' "$dir/$name"
      return 0
    fi
  done
  return 1
}

run() {
  if (( DRY_RUN )); then return 0; fi
  "$@"
}

# Line numbers of the managed block as "begin end", or nothing if the rc file
# has no well-formed one.
#
# Both markers must match a WHOLE line, with the end after the begin. A
# substring test is not good enough: BLOCK_END contains BLOCK_BEGIN, so a
# fixed-string grep for the begin marker also matches the end marker, and any
# hand-written comment mentioning personal-scripts matches too. Acting on such
# a false positive with a marker-to-marker range that never terminates would
# take out every line from there to end of file.
block_range() {
  [[ -f "$SHELL_RC" ]] || return 0
  awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" '
    !b && $0 == begin { b = NR; next }
    b && !e && $0 == end { e = NR }
    END { if (b && e) print b, e }
  ' "$SHELL_RC"
}

# A marker line on its own, without a matching partner, means someone edited
# the block by hand or an earlier run died midway. Rewriting is not safe.
stray_marker() {
  [[ -f "$SHELL_RC" ]] || return 1
  grep -qxF -e "$BLOCK_BEGIN" -e "$BLOCK_END" "$SHELL_RC"
}

linked=0; updated=0; unchanged=0; pruned=0; skipped=0

# Names deliberately left unlinked this run, so the prune pass below can say
# why their link is going rather than claiming the script left bin/.
skipped_names=()

# --- link everything in bin/ ------------------------------------------------

if (( DRY_RUN )); then
  printf '==> Dry run, nothing will be changed\n\n'
fi

printf '==> Linking %s -> %s\n' "$BIN_SRC" "$TARGET"

if [[ ! -d "$TARGET" ]]; then
  printf '    create %s\n' "$TARGET"
  run mkdir -p "$TARGET"
fi

names=()
for src in "$BIN_SRC"/*; do
  # The glob is literal when bin/ is empty, so confirm the file exists.
  [[ -f "$src" ]] || continue

  base="${src##*/}"
  case "$base" in .*) continue ;; esac

  if [[ ! -x "$src" ]]; then
    printf '    skip   %-24s not executable (chmod +x to install it)\n' "$base"
    skipped_names+=("$(command_name "$src")")
    skipped=$(( skipped + 1 ))
    continue
  fi

  name="$(command_name "$src")"
  if [[ -z "$name" ]]; then
    printf '    skip   %-24s cannot derive a command name\n' "$base"
    skipped=$(( skipped + 1 ))
    continue
  fi

  # A script that needs a tool this machine may not have. --no-sandbox is the
  # opt-out for the sbx ones; a tool that is simply missing only warns, because
  # it can be installed after this runs and a link that silently never appeared
  # is harder to diagnose than a command that says what it wants.
  req="$(required_tool "$src")"
  if [[ -n "$req" ]]; then
    if (( NO_SANDBOX )) && [[ "$req" == sbx ]]; then
      printf '    skip   %-24s needs sbx, --no-sandbox\n' "$name"
      skipped_names+=("$name")
      skipped=$(( skipped + 1 ))
      continue
    fi
    if ! command -v "$req" >/dev/null 2>&1; then
      hint=''
      [[ "$req" == sbx ]] && hint=' (--no-sandbox leaves it out)'
      printf '    NOTE   %-24s needs %s, not installed%s\n' "$name" "$req" "$hint" >&2
    fi
  fi

  # Two scripts reducing to one command (foo.sh and foo.py) would otherwise
  # both link to $TARGET/foo, each run repointing it at the other and
  # reporting the flip as a normal update.
  if in_list "$name" ${names[@]+"${names[@]}"}; then
    printf '    SKIP   %-24s command name already taken by another script\n' "$base" >&2
    skipped=$(( skipped + 1 ))
    continue
  fi

  names+=("$name")
  dest="$TARGET/$name"

  if [[ -L "$dest" ]]; then
    current="$(link_target "$dest")"
    if [[ "$current" == "$src" ]]; then
      printf '    ok     %-24s already linked\n' "$name"
      unchanged=$(( unchanged + 1 ))
    elif is_ours "$current"; then
      printf '    update %-24s was %s\n' "$name" "$current"
      run ln -sfn "$src" "$dest"
      updated=$(( updated + 1 ))
    else
      printf '    SKIP   %-24s symlink to %s is not ours\n' "$name" "$current" >&2
      skipped=$(( skipped + 1 ))
      continue
    fi
  elif [[ -e "$dest" ]]; then
    printf '    SKIP   %-24s a real file is already there\n' "$name" >&2
    skipped=$(( skipped + 1 ))
    continue
  else
    printf '    link   %-24s -> %s\n' "$name" "$src"
    run ln -sfn "$src" "$dest"
    linked=$(( linked + 1 ))
  fi

  if other="$(shadowed_by "$name")"; then
    printf '    NOTE   %-24s also found at %s\n' "$name" "$other" >&2
  fi
done

# --- prune links to scripts that are gone -----------------------------------

for dest in "$TARGET"/*; do
  [[ -L "$dest" ]] || continue

  current="$(link_target "$dest")"
  is_ours "$current" || continue

  name="${dest##*/}"
  if in_list "$name" ${names[@]+"${names[@]}"}; then continue; fi

  if in_list "$name" ${skipped_names[@]+"${skipped_names[@]}"}; then
    printf '    prune  %-24s left out this run\n' "$name"
  elif [[ -e "$current" ]]; then
    printf '    prune  %-24s no longer in bin/\n' "$name"
  else
    printf '    prune  %-24s target is gone\n' "$name"
  fi
  run rm -f "$dest"
  pruned=$(( pruned + 1 ))
done

printf '\n    %d linked, %d updated, %d unchanged, %d pruned, %d skipped\n\n' \
  "$linked" "$updated" "$unchanged" "$pruned" "$skipped"

# --- collect shell fragments to source --------------------------------------

sources=()
if [[ -d "$SHELL_SRC" ]]; then
  printf '==> Sourcing fragments from %s\n' "$SHELL_SRC"

  for src in "$SHELL_SRC"/*; do
    [[ -f "$src" ]] || continue

    base="${src##*/}"
    case "$base" in .*) continue ;; esac

    # A sourced file is never executed, so the executable bit is meaningless
    # here and suggests the file was meant for bin/ instead.
    if [[ -x "$src" ]]; then
      printf '    NOTE   %-24s is executable; sourced files need not be (chmod -x)\n' "$base" >&2
    fi

    printf '    source %s\n' "$base"
    sources+=("$src")
  done

  if (( ${#sources[@]} == 0 )); then
    printf '    (none)\n'
  fi
  printf '\n'
fi

# --- converge the managed rc block ------------------------------------------

# The single quotes below are deliberate: "$PATH" has to reach the rc file as
# the literal three characters, to be expanded by the shell that reads it, not
# by this one.
# shellcheck disable=SC2016
managed_block() {
  printf '%s\n' "$BLOCK_BEGIN"
  printf 'case ":$PATH:" in\n'
  printf '  *":%s:"*) ;;\n' "$TARGET"
  printf '  *) export PATH="%s:$PATH" ;;\n' "$TARGET"
  printf 'esac\n'
  local s
  for s in ${sources[@]+"${sources[@]}"}; do
    printf 'source "%s"\n' "$s"
  done
  printf '%s\n' "$BLOCK_END"
}

desired="$(managed_block)"
has_block=0
range="$(block_range)"

if [[ -n "$range" ]]; then
  has_block=1
  block_begin_line="${range%% *}"
  block_end_line="${range##* }"
  current_block="$(sed -n "${block_begin_line},${block_end_line}p" "$SHELL_RC")"
  if [[ "$current_block" == "$desired" ]]; then
    printf '==> %s is already up to date\n' "$SHELL_RC"
    exit 0
  fi
  printf '==> %s needs updating:\n\n' "$SHELL_RC"
elif stray_marker; then
  printf 'Found a %s or %s line in %s, but not a complete block.\n' \
    "$BLOCK_BEGIN" "$BLOCK_END" "$SHELL_RC" >&2
  printf 'Refusing to rewrite it, because guessing where the block ends risks\n' >&2
  printf 'discarding the rest of the file. Repair or delete those lines first.\n' >&2
  exit 1
else
  printf '==> %s needs this block:\n\n' "$SHELL_RC"
fi

printf '%s\n' "$desired" | sed 's/^/    /'
printf '\n'

if (( DRY_RUN )); then
  printf '    Dry run: %s not modified.\n' "$SHELL_RC"
  exit 0
fi

reply=n
if (( ASSUME_YES )); then
  reply=y
elif [[ -t 0 ]]; then
  if (( has_block )); then
    printf 'Update the block in %s? [y/N] ' "$SHELL_RC"
  else
    printf 'Append this to %s? [y/N] ' "$SHELL_RC"
  fi
  read -r reply || reply=n
fi

case "$reply" in
  [yY]*)
    # Back up before either kind of edit, not just the rewrite. Appending is
    # the safer of the two, but "there is a .bak" should not depend on which
    # path ran. Skipped only when there is no file yet to copy.
    backup=''
    if [[ -f "$SHELL_RC" ]]; then
      cp -p "$SHELL_RC" "$SHELL_RC.bak"
      backup=" (backup at $SHELL_RC.bak)"
    fi

    if (( has_block )); then
      # Temp files alongside the target so the mv is a same-filesystem rename,
      # and the rc file is never left half-written. Both are created before the
      # trap covers them, and the trap covers both: an awk failure under set -e
      # exits between them, and the one not yet cleaned would otherwise be left
      # behind.
      tmp=''
      block_file=''
      trap 'rm -f "$tmp" "$block_file" 2>/dev/null || true' EXIT

      tmp="$(mktemp "$SHELL_RC.XXXXXX")"
      block_file="$(mktemp)"
      printf '%s\n' "$desired" > "$block_file"

      # Substitute in place rather than delete-and-append, so the block keeps
      # its position relative to everything else in the file.
      #
      # Addressed by the line numbers block_range already validated, not by
      # re-matching the markers. The replaced span is then bounded on both
      # ends by construction, so no marker mishap can run to end of file.
      awk -v b="$block_begin_line" -v e="$block_end_line" -v newfile="$block_file" '
        NR == b {
          while ((getline line < newfile) > 0) print line
          close(newfile)
          next
        }
        NR > b && NR <= e { next }
        { print }
      ' "$SHELL_RC" > "$tmp"
      rm -f "$block_file"

      chmod "$(file_mode "$SHELL_RC")" "$tmp"
      mv "$tmp" "$SHELL_RC"

      printf '    Updated %s%s.\n' "$SHELL_RC" "$backup"
    else
      printf '\n' >> "$SHELL_RC"
      printf '%s\n' "$desired" >> "$SHELL_RC"
      printf '    Appended to %s%s.\n' "$SHELL_RC" "$backup"
    fi
    printf '    Run: source %s\n' "$SHELL_RC"
    ;;
  *)
    printf '\n    Not modified. Put the block above in %s yourself,\n' "$SHELL_RC"
    printf '    or apply it to the current shell only:\n\n'
    # Literal "$PATH" again: this line is printed for the user to copy, not run.
    # shellcheck disable=SC2016
    printf '        export PATH="%s:$PATH"\n' "$TARGET"
    for s in ${sources[@]+"${sources[@]}"}; do
      printf '        source "%s"\n' "$s"
    done
    ;;
esac
