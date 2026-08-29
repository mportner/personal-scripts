#!/usr/bin/env bash
#
# File:    uninstall.sh
# Created: 2026-08-21
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Reverses setup.sh: removes the symlinks it created and, on confirmation, the
# managed block it added to the shell rc file (the PATH entry, and a source
# line per shell/ fragment when there are any).
#
# Only symlinks resolving into this repo are removed. Regular files and links
# pointing anywhere else are left alone, so this cannot damage entries another
# installer owns in the same directory.
#
# Targets bash 3.2, the version macOS ships.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET="${PERSONAL_SCRIPTS_BIN:-$HOME/.local/bin}"
SHELL_RC="${ZDOTDIR:-$HOME}/.zshrc"

BLOCK_BEGIN='# personal-scripts'
BLOCK_END='# personal-scripts end'

ASSUME_YES=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: uninstall.sh [options]

Removes the symlinks setup.sh created in ~/.local/bin, and offers to remove the
managed block it added to your shell rc file.

Only symlinks pointing into this repo are removed. Anything else in the
directory is left untouched.

Options:
  -y, --yes       Skip the confirmation prompt for editing the shell rc file.
  -n, --dry-run   Report what would be removed and exit without removing it.
  -h, --help      Show this help.

Environment:
  PERSONAL_SCRIPTS_BIN   Link directory (default ~/.local/bin).
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -y|--yes)     ASSUME_YES=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

link_target() { readlink -- "$1" 2>/dev/null || printf ''; }

is_ours() { [[ "$1" == "$REPO_DIR"/* ]]; }

# Octal permissions of a file, falling back to 644. GNU stat spells this -c
# and BSD/macOS spells it -f, but they cannot be chained the other way round:
# `stat -f` on GNU is not an error, it reports FILE SYSTEM status and exits 0
# with output that is not a mode. See the matching comment in setup.sh.
file_mode() {
  local mode
  mode="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true)"
  case "$mode" in
    ''|*[!0-7]*) mode=644 ;;
  esac
  printf '%s' "$mode"
}

run() {
  if (( DRY_RUN )); then return 0; fi
  "$@"
}

# Line numbers of the managed block as "begin end", or nothing if the rc file
# has no well-formed one. See the matching comment in setup.sh: BLOCK_END
# contains BLOCK_BEGIN, so a substring match finds a "block" in files that have
# none, and deleting an unterminated marker range takes the rest of the file
# with it.
block_range() {
  [[ -f "$SHELL_RC" ]] || return 0
  awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" '
    !b && $0 == begin { b = NR; next }
    b && !e && $0 == end { e = NR }
    END { if (b && e) print b, e }
  ' "$SHELL_RC"
}

stray_marker() {
  [[ -f "$SHELL_RC" ]] || return 1
  grep -qxF -e "$BLOCK_BEGIN" -e "$BLOCK_END" "$SHELL_RC"
}

if (( DRY_RUN )); then
  printf '==> Dry run, nothing will be removed\n\n'
fi

# --- remove our symlinks ----------------------------------------------------

removed=0
kept=0

printf '==> Removing links to %s from %s\n' "$REPO_DIR" "$TARGET"

if [[ -d "$TARGET" ]]; then
  for dest in "$TARGET"/*; do
    # The glob is literal when the directory is empty.
    [[ -e "$dest" || -L "$dest" ]] || continue

    name="${dest##*/}"

    if [[ ! -L "$dest" ]]; then
      kept=$(( kept + 1 ))
      continue
    fi

    current="$(link_target "$dest")"
    if ! is_ours "$current"; then
      kept=$(( kept + 1 ))
      continue
    fi

    printf '    remove %-24s -> %s\n' "$name" "$current"
    run rm -f "$dest"
    removed=$(( removed + 1 ))
  done
else
  printf '    %s does not exist, nothing to remove\n' "$TARGET"
fi

printf '\n    %d removed, %d left alone\n\n' "$removed" "$kept"

# --- remove the managed block -----------------------------------------------

range="$(block_range)"

if [[ -z "$range" ]]; then
  if stray_marker; then
    printf 'Found a %s or %s line in %s, but not a complete block.\n' \
      "$BLOCK_BEGIN" "$BLOCK_END" "$SHELL_RC" >&2
    printf 'Refusing to edit it, because guessing where the block ends risks\n' >&2
    printf 'deleting the rest of the file. Remove those lines by hand.\n' >&2
    exit 1
  fi
  printf '==> No managed block in %s\n' "$SHELL_RC"
  exit 0
fi

block_begin_line="${range%% *}"
block_end_line="${range##* }"

printf '==> %s still has the managed block:\n\n' "$SHELL_RC"
sed -n "${block_begin_line},${block_end_line}p" "$SHELL_RC" | sed 's/^/    /'
printf '\n'

if (( DRY_RUN )); then
  printf '    Dry run: %s not modified.\n' "$SHELL_RC"
  exit 0
fi

reply=n
if (( ASSUME_YES )); then
  reply=y
elif [[ -t 0 ]]; then
  printf 'Remove it from %s? [y/N] ' "$SHELL_RC"
  read -r reply || reply=n
fi

case "$reply" in
  [yY]*)
    cp -p "$SHELL_RC" "$SHELL_RC.bak"

    # Temp file alongside the target so the mv is a same-filesystem rename,
    # and the rc file is never left half-written.
    tmp="$(mktemp "$SHELL_RC.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT

    # Drop the block by the line numbers block_range validated, plus the blank
    # line setup.sh appended just before it. Only that one line: stripping
    # every trailing blank would also eat deliberate spacing the user put at
    # the end of their own rc file.
    del_begin="$block_begin_line"
    if (( del_begin > 1 )); then
      prev="$(sed -n "$(( del_begin - 1 ))p" "$SHELL_RC")"
      [[ -z "${prev//[[:space:]]/}" ]] && del_begin=$(( del_begin - 1 ))
    fi

    awk -v b="$del_begin" -v e="$block_end_line" 'NR < b || NR > e' "$SHELL_RC" > "$tmp"

    chmod "$(file_mode "$SHELL_RC")" "$tmp"
    mv "$tmp" "$SHELL_RC"

    printf '    Removed from %s (backup at %s.bak).\n' "$SHELL_RC" "$SHELL_RC"
    printf '    Open a new shell to drop it from PATH.\n'
    ;;
  *)
    printf '\n    Left in place. Delete the block above from %s yourself\n' "$SHELL_RC"
    printf '    if you want %s off your PATH.\n' "$TARGET"
    ;;
esac
