#!/bin/sh
#
# File:    stamp-subscription-type.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Adds subscriptionType to the OAuth credential file sbx stages in the sandbox,
# taking the value from SBX_CLAUDE_SUBSCRIPTION_TYPE.
#
# Why this exists. The claude agent spec inside sbx (0.39.0) renders the
# credential file from a fixed template:
#
#   {"claudeAiOauth":{"accessToken":"...","refreshToken":"...",
#                     "expiresAt":...,"scopes":[...]}}
#
# There is no subscriptionType in it, so Claude Code cannot tell which plan the
# session runs on and falls back to labelling the sandbox "Claude API". That
# misreports the billing: the session is authenticated against a subscription,
# not API credits, and a banner that says otherwise invites an unnecessary
# /login.
#
# Nothing secret passes through here. The tokens in this file are the proxy's
# fixed placeholders, identical in every sandbox; the real credential stays on
# the host and the egress proxy substitutes it. The plan name is not a secret
# either, which is why it can travel as a plain environment variable.
#
# The host side is resolve_subscription_type() in lib/sandbox-launcher.sh, which
# picks the value and passes it to `sbx create -e`.
#
# It runs as a startup command on every container start and is idempotent: a
# file that already carries a subscriptionType is left alone, including one
# Claude Code itself wrote after a token refresh.
#
# POSIX sh, run by `sh` from the kit's startup command.

set -u

note() { echo "claude-config: $*" >&2; }

type="${SBX_CLAUDE_SUBSCRIPTION_TYPE:-}"
[ -n "$type" ] || exit 0

# ${HOME:-} rather than $HOME: set -u would abort on an unset HOME, and this
# runs from a startup dispatcher that takes the whole chain down on a non-zero
# status. An empty HOME simply finds no file and exits 0.
target="${HOME:-}/.claude/.credentials.json"
[ -f "$target" ] || exit 0

# Plan names are lower case words (max, pro, team, enterprise). Anything else is
# refused rather than passed to jq: the value arrives from the host environment,
# and a credential file is the wrong place to find out that an assumption about
# its shape was wrong.
#
# Filtered with `tr` under LC_ALL=C rather than a [!a-z0-9_] glob, which is not
# the test it looks like: in a UTF-8 locale the a-z range collates
# case-insensitively, so the glob accepts MAX and every other upper-case
# spelling. The C locale makes the range the 26 bytes it appears to be.
if [ -n "$(printf '%s' "$type" | LC_ALL=C tr -d 'a-z0-9_')" ]; then
  note "ignoring SBX_CLAUDE_SUBSCRIPTION_TYPE, '$type' is not a plan name"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { note "jq is not installed, leaving $target alone"; exit 0; }

# One read, so a concurrent write cannot land between the two questions. `//
# empty` distinguishes "no OAuth entry" from "an entry with no type": the first
# is an API-key sandbox that this must not touch, the second is the case this
# exists for.
current="$(jq -r 'if has("claudeAiOauth") then (.claudeAiOauth.subscriptionType // "") else "absent" end' \
  "$target" 2>/dev/null)" || current=unreadable

case "$current" in
  unreadable) note "$target is not readable JSON, left untouched"; exit 0 ;;
  absent)     note "$target carries no OAuth entry, left untouched"; exit 0 ;;
  '')         ;;
  *)          exit 0 ;;
esac

# Written beside the target so the final mv is a same-filesystem rename, which
# is atomic: Claude Code reads this file at startup and must never see a partial
# one. The mode is set before the rename, so it is never briefly readable by
# anyone else under its real name.
tmp="$target.stamp.$$"
trap 'rm -f "$tmp" 2>/dev/null' EXIT INT TERM

if ! jq --arg t "$type" '.claudeAiOauth.subscriptionType = $t' "$target" > "$tmp" 2>/dev/null; then
  note "could not rewrite $target, left untouched"
  exit 0
fi

[ -s "$tmp" ] || { note "rewrite of $target came out empty, left untouched"; exit 0; }

chmod 600 "$tmp" 2>/dev/null

if mv "$tmp" "$target"; then
  note "recorded the $type subscription in $target"
else
  note "could not replace $target, left untouched"
fi

exit 0
