#
# File:    sbx-kit-wrapper.zsh
# Created: 2026-08-21
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Auto-applies this repo's kits to new claude sandboxes.
#
# sbx has no config file or env var for a default kit; --kit is a per-invocation
# flag applied at creation time. This wrapper supplies them so `sbx run claude`
# and `sbx create claude` behave as if they were the default.
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

# Order matters: kits compose in --kit order, and dev-tools' startup command
# assumes claude-config has already had its turn at ~/.claude/settings.json.
#
# Override by setting SBX_DEFAULT_KITS before sourcing this file, e.g. to run
# without the toolchain kit:
#     SBX_DEFAULT_KITS=(~/personal-scripts/claude-config-kit)
if (( ! ${+SBX_DEFAULT_KITS} )); then
  SBX_DEFAULT_KITS=(
    "${SBX_KIT_WRAPPER_DIR:h}/claude-config-kit"
    "${SBX_KIT_WRAPPER_DIR:h}/dev-tools-kit"
  )
fi

# Array expansions are explicitly subscripted and quoted throughout. This file
# is sourced into an interactive shell, so it inherits whatever options the user
# has set: under `setopt shwordsplit` a bare $SBX_DEFAULT_KITS splits a kit path
# containing a space and the kit is silently dropped, and under `setopt
# globsubst` a path containing glob metacharacters triggers filename generation
# and NOMATCH kills the whole function. Neither happens with stock options, but
# neither costs anything to prevent.
sbx() {
  local arg kit
  local -i inject=0
  local -a kit_args

  # Only run/create take --kit, and the kits write ~/.claude and the workspace,
  # so they are only meaningful for the claude agent. Anything else passes
  # straight through.
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

  if (( inject == 1 )); then
    for kit in "${SBX_DEFAULT_KITS[@]}"; do
      # Say so rather than quietly dropping a kit. Silently running without one
      # looks identical to running with it until you notice the status line is
      # missing, or that the agent is back to hand-rolling a pnpm shim.
      if [[ -d "$kit" ]]; then
        kit_args+=(--kit "$kit")
      else
        print -u2 "sbx-kit-wrapper: no kit at $kit, continuing without it"
      fi
    done
  fi

  if (( $#kit_args )); then
    command sbx "$1" "${kit_args[@]}" "${@:2}"
  else
    command sbx "$@"
  fi
}
