#
# File:    output.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Generic console scaffolding, with nothing sandbox-specific about it, shared
# by any script under bin/: a tagged fatal-error printer, a two-space status
# line, a step banner, and a guard for options that consume a value.
#
# This file defines functions only. It must be SOURCED, not executed: running
# it in a subprocess would define them there and throw them away when the
# subprocess exits. That is why it lives in lib/ rather than bin/, has no
# shebang, and is not executable, matching the convention shell/ already
# follows for sourced files. setup.sh only links bin/ and shell/ onto PATH, so
# lib/ needs no exclusion of its own.
#
# The sourcing script must set PROG to its own command name before the first
# call to die(), e.g. PROG="research-sandbox".

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }
note() { printf '    %s\n' "$1"; }
step() { printf '==> %s\n' "$1"; }

# An option that consumes a value must confirm one is there. Otherwise the
# inner `shift` empties "$@" and the loop's own `shift` fails, which under
# set -e exits the script silently with no diagnostic at all.
need_value() { (( $# >= 2 )) || die "$1 needs a value"; }
