#
# File:    sbx-kit-wrapper.zsh
# Created: 2026-08-21
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Auto-applies the claude-config kit to new claude sandboxes.
#
# sbx has no config file or env var for a default kit; --kit is a per-invocation
# flag applied at creation time. This wrapper supplies it so `sbx run claude`
# and `sbx create claude` behave as if it were the default.
#
# This file defines a shell function, so it must be SOURCED, not executed. That
# is why it lives in shell/ rather than bin/, and why it has no shebang and is
# not executable: running it in a subprocess would define sbx() there and then
# throw it away when the subprocess exits.
#
# Source from ~/.zshrc:
#     source ~/personal-scripts/shell/sbx-kit-wrapper.zsh

# Resolved from this file's own location, so the repo works wherever it is
# cloned rather than only at ~/personal-scripts. %x is the file containing the
# current code, which is correct when sourced; :A makes it absolute and
# resolves symlinks, :h takes the dirname. Twice, to reach the repo root.
SBX_KIT_WRAPPER_DIR="${${(%):-%x}:A:h}"
SBX_DEFAULT_KIT="${SBX_DEFAULT_KIT:-${SBX_KIT_WRAPPER_DIR:h}/claude-config-kit}"

sbx() {
  local kit="$SBX_DEFAULT_KIT"
  local arg
  local -i inject=0

  # Only run/create take --kit, and the kit writes ~/.claude, so it is only
  # meaningful for the claude agent. Anything else passes straight through.
  case "$1" in
    run|create)
      for arg in "$@"; do
        case "$arg" in
          # Already asked for a kit explicitly: respect that, add nothing.
          --kit|--kit=*) inject=-1 ;;
          # "--" ends sbx's own args; anything after belongs to the agent.
          --) break ;;
          claude) (( inject >= 0 )) && inject=1 ;;
        esac
      done
      ;;
  esac

  # Say so rather than quietly dropping the kit. Silently running without it
  # looks identical to running with it until you notice the status line is
  # missing and the settings never applied.
  if (( inject == 1 )) && [[ ! -d "$kit" ]]; then
    print -u2 "sbx-kit-wrapper: no kit at $kit, running without --kit"
    inject=0
  fi

  if (( inject == 1 )); then
    command sbx "$1" --kit "$kit" "${@:2}"
  else
    command sbx "$@"
  fi
}
