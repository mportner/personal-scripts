#!/usr/bin/env bash
#
# File:    research-sandbox.sh
# Created: 2026-08-22
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Creates an sbx sandbox for research and planning: open network egress, a
# private clone of a GitHub repo, and no access to the host filesystem.
#
# Three mechanisms combine, because no single one covers it:
#
#   network    research-kit declares permissions.network.allow ["**"], which
#              becomes a policy scoped to this sandbox alone, layered over the
#              global preset. `sbx policy init allow-all` would be global.
#   filesystem --clone gives the sandbox a private copy of the repo on a
#              container volume instead of bind-mounting a host directory.
#              Only a throwaway seed clone is exposed, read-only, and only at
#              /run/sandbox/source.
#   GitHub     a fine-grained PAT stored SANDBOX-SCOPED, so this sandbox never
#              inherits the global token. The secret is staged before creation,
#              so the broad token is never injected even briefly.
#
# GitHub tokens have no branch granularity: a token that can push at all can
# push anywhere in the repos it covers. What actually stops a push to the
# default branch is a repository ruleset carrying the `pull_request` rule with
# an empty bypass list. This script warns when the target repo lacks one.
#
# Targets bash 3.2, the version macOS ships.
set -euo pipefail

# Resolved through symlinks: setup.sh installs this as ~/.local/bin/<name>, so
# BASH_SOURCE is the symlink and its dirname is the link directory, not the
# repo. pwd -P does not help, because the link directory is itself real.
#
# Walked by hand rather than with `readlink -f`: macOS only gained -f in 12.3,
# and falling back to the unresolved path on older systems would silently put
# REPO_DIR one level above the link directory, reporting the kits as missing.
# Plain `readlink` is available everywhere.
SELF="${BASH_SOURCE[0]}"
while [[ -L "$SELF" ]]; do
  link="$(readlink -- "$SELF")"
  case "$link" in
    /*) SELF="$link" ;;
    *)  SELF="$(cd -- "$(dirname -- "$SELF")" && pwd -P)/$link" ;;
  esac
done
REPO_DIR="$(cd -- "$(dirname -- "$SELF")/.." && pwd -P)"
CONFIG_KIT="$REPO_DIR/claude-config-kit"
RESEARCH_KIT="$REPO_DIR/research-kit"
SEED_ROOT="${RESEARCH_SEED_ROOT:-$HOME/.local/state/sbx-research}"
TOKEN_REF="${RESEARCH_GH_TOKEN_REF:-}"

NAME=""
NO_TOKEN=0
DESTROY=0
FORCE=0
DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: research-sandbox [options] REPO
       research-sandbox --destroy NAME

Creates a sandbox for research and planning on a GitHub repo: full network
egress, a private clone on a container volume, and no host filesystem access.

REPO is owner/repo or a https://github.com/owner/repo URL.

Options:
  -n, --name NAME       Sandbox name (default: research-<repo>).
  -r, --token-ref REF   1Password reference for the GitHub token, e.g.
                        op://Private/gh-research/credential. Stored scoped to
                        this sandbox only, so the global token is never used.
      --no-token        Create with no GitHub credential at all. Public repos
                        still clone; push and PR will not work.
      --destroy NAME    Remove a research sandbox, its seed clone, and its
                        scoped secret.
  -f, --force           Re-clone the seed directory if it already exists.
  -y, --yes             Skip confirmation prompts.
      --dry-run         Print what would happen and exit.
  -h, --help            Show this help.

Environment:
  RESEARCH_GH_TOKEN_REF   Default for --token-ref.
  RESEARCH_SEED_ROOT      Seed clone directory (default ~/.local/state/sbx-research).

The token needs Contents: write, Pull requests: write and Metadata: read on
the repos you want researched, and nothing else. Branch protection comes from
the repo's ruleset, not the token.
EOF
}

run() {
  if (( DRY_RUN )); then
    printf '    would run: %s\n' "$*"
    return 0
  fi
  "$@"
}

die() { printf 'research-sandbox: %s\n' "$1" >&2; exit 1; }
note() { printf '    %s\n' "$1"; }
step() { printf '==> %s\n' "$1"; }

# An option that consumes a value must confirm one is there. Otherwise the
# inner `shift` empties "$@" and the loop's own `shift` fails, which under
# set -e exits the script silently with no diagnostic at all.
need_value() { (( $# >= 2 )) || die "$1 needs a value"; }

while (( $# > 0 )); do
  case "$1" in
    -n|--name)      need_value "$@"; NAME="$2"; shift ;;
    -r|--token-ref) need_value "$@"; TOKEN_REF="$2"; shift ;;
    --no-token)     NO_TOKEN=1 ;;
    --destroy)      need_value "$@"; DESTROY=1; NAME="$2"; shift ;;
    -f|--force)     FORCE=1 ;;
    -y|--yes)       ASSUME_YES=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    *)              REPO_ARG="${REPO_ARG:-$1}" ;;
  esac
  shift
done

command -v sbx >/dev/null 2>&1 || die "sbx is not installed"
command -v git >/dev/null 2>&1 || die "git is not installed"

# --- destroy ----------------------------------------------------------------

if (( DESTROY )); then
  [[ -n "$NAME" ]] || die "--destroy needs a sandbox name"
  step "Destroying research sandbox $NAME"
  note "sandbox      $NAME"
  note "seed clone   $SEED_ROOT/$NAME"
  note "scoped github secret, if any"

  # Unreviewed commits live only in the sandbox until they are pushed or
  # fetched, so this can lose work that exists nowhere else.
  if (( ! ASSUME_YES )) && (( ! DRY_RUN )); then
    if [[ -t 0 ]]; then
      printf '\nRemove these? Unpushed commits in the sandbox are lost. [y/N] '
      read -r reply || reply=n
    else
      reply=n
    fi
    case "$reply" in
      [yY]*) ;;
      *) die "cancelled (use --yes to skip this prompt)" ;;
    esac
  fi

  printf '\n'
  run sbx rm "$NAME" -f || note "sandbox $NAME not found, continuing"

  seed="$SEED_ROOT/$NAME"
  if [[ -d "$seed" ]]; then
    note "removing seed clone $seed"
    run rm -rf "$seed"
  fi

  # Leaving this behind would silently apply to any future sandbox that
  # happens to reuse the name.
  # `yes |` feeds the confirmation prompt, but the pipeline exits non-zero even
  # when the delete succeeds, so its status says nothing. Check the store
  # afterwards instead: this is the step that has to be trustworthy, since a
  # leftover token would silently apply to a later sandbox that reused the name.
  # Not gated on a prior `secret ls` for the reason given in rollback().
  if (( DRY_RUN )); then
    printf '    would run: sbx secret rm --sandbox %s github\n' "$NAME"
  else
    yes | sbx secret rm --sandbox "$NAME" github >/dev/null 2>&1 || true
    if secret_present; then
      note "WARNING: scoped secret still present. Remove it with:"
      note "  sbx secret rm --sandbox $NAME github"
    else
      note "no scoped secret left behind"
    fi
  fi

  step "Done"
  exit 0
fi

# --- resolve the repo -------------------------------------------------------

[[ -n "${REPO_ARG:-}" ]] || { usage >&2; exit 2; }

case "$REPO_ARG" in
  https://github.com/*)
    slug="${REPO_ARG#https://github.com/}"
    ;;
  git@github.com:*)
    slug="${REPO_ARG#git@github.com:}"
    ;;
  */*)
    slug="$REPO_ARG"
    ;;
  *)
    die "REPO must be owner/repo or a github.com URL (got: $REPO_ARG)"
    ;;
esac
slug="${slug%.git}"
slug="${slug%/}"

# Exactly one slash. owner and repo are often identical (cli/cli), so that is
# not a parse failure.
case "$slug" in
  */*/*) die "expected owner/repo, got a deeper path: $REPO_ARG" ;;
  */*)   ;;
  *)     die "expected owner/repo, got: $REPO_ARG" ;;
esac

owner="${slug%%/*}"
repo="${slug##*/}"
[[ -n "$owner" && -n "$repo" ]] || die "cannot parse owner/repo from: $REPO_ARG"

CLONE_URL="https://github.com/$owner/$repo.git"
NAME="${NAME:-research-$repo}"
SEED="$SEED_ROOT/$NAME"

# --- preflight --------------------------------------------------------------

step "Preflight"
[[ -d "$CONFIG_KIT" ]]   || die "missing kit: $CONFIG_KIT"
[[ -d "$RESEARCH_KIT" ]] || die "missing kit: $RESEARCH_KIT"
note "kits      $CONFIG_KIT"
note "          $RESEARCH_KIT"
note "repo      $owner/$repo"
note "sandbox   $NAME"
note "seed      $SEED"

if (( NO_TOKEN )); then
  note "token     none (--no-token): push and PR will not work"
elif [[ -n "$TOKEN_REF" ]]; then
  case "$TOKEN_REF" in
    op://*)
      command -v op >/dev/null 2>&1 || die \
"op is not installed, so the 1Password reference cannot be resolved.
  brew install 1password-cli
then enable 'Integrate with 1Password CLI' in the 1Password app's Developer
settings. Or pass --no-token to create a sandbox with no GitHub credential."
      ;;
  esac
  note "token     $TOKEN_REF (scoped to this sandbox)"
else
  die \
"no GitHub token reference. Set RESEARCH_GH_TOKEN_REF or pass --token-ref,
  e.g. --token-ref op://Private/gh-research/credential
Use --no-token to deliberately create a sandbox with no GitHub access.
Do not point this at your default token: this sandbox reads untrusted web
content, and the global token carries repo and admin rights."
fi

# --- warn when the default branch is unprotected ----------------------------
# A narrow token still permits pushing anywhere in the repos it covers.
# The ruleset is the only thing keeping the agent off the default branch.

# jq is only needed here, so it is checked here rather than as a hard
# dependency. Without the guard a missing jq yields an empty rule list, which
# reads as "no ruleset" and fires a warning that is not true.
if ! command -v gh >/dev/null 2>&1; then
  note "ruleset   skipped, gh not installed on the host"
elif ! command -v jq >/dev/null 2>&1; then
  note "ruleset   skipped, jq not installed on the host"
else
  if rules="$(gh api "repos/$owner/$repo/rulesets" 2>/dev/null)"; then
    protected=0
    for id in $(printf '%s' "$rules" | jq -r '.[]?.id' 2>/dev/null); do
      detail="$(gh api "repos/$owner/$repo/rulesets/$id" 2>/dev/null || printf '{}')"
      if printf '%s' "$detail" | jq -e '
            .enforcement == "active"
            and (.conditions.ref_name.include // [] | index("~DEFAULT_BRANCH"))
            and ([.rules[]?.type] | index("pull_request"))
          ' >/dev/null 2>&1; then
        protected=1
        break
      fi
    done
    if (( protected )); then
      note "ruleset   default branch requires a pull request"
    else
      printf '    WARNING  %s/%s has no active ruleset requiring a PR on its\n' "$owner" "$repo" >&2
      printf '             default branch. A token that can push at all can push\n' >&2
      printf '             there directly. Add a ruleset with the pull_request rule.\n' >&2
    fi
  else
    note "ruleset   could not check (no access to $owner/$repo, or repo not found)"
  fi
fi

if (( DRY_RUN )); then
  printf '\n'
  step "Dry run, nothing was created"
fi

# --- seed clone -------------------------------------------------------------

printf '\n'
step "Seed clone"

if [[ -d "$SEED" ]]; then
  if (( FORCE )); then
    note "removing existing $SEED"
    run rm -rf "$SEED"
  else
    die "$SEED already exists. Use --force to re-clone, or --destroy $NAME first."
  fi
fi

run mkdir -p "$SEED_ROOT"
# Cloned on the host only to seed --clone. The sandbox gets its own copy on a
# container volume; this directory is exposed to it read-only and nothing else.
run git clone --quiet "$CLONE_URL" "$SEED" || die "clone failed: $CLONE_URL"
(( DRY_RUN )) || note "cloned $CLONE_URL"

# --- stage the scoped secret BEFORE creating --------------------------------
# Staging first is the point: a secret added after creation would leave a
# window in which the sandbox held the global token.

if (( ! NO_TOKEN )); then
  printf '\n'
  step "Staging sandbox-scoped GitHub secret"
  run sbx secret set --sandbox "$NAME" github --ref "$TOKEN_REF" \
    || die "could not store the scoped secret; sandbox not created"
fi

# --- create -----------------------------------------------------------------

# Roll back on failure. The secret is staged before creation deliberately, so
# a failed create would otherwise leave a live credential scoped to a sandbox
# that does not exist, and it would silently apply to any later sandbox that
# reused the name. That is the exact hazard --destroy exists to prevent, so it
# must not be reachable by simply having creation fail.
# Exact string compare rather than a regex: sandbox names may contain periods
# and plus signs, which are ERE metacharacters. "a+b" as a pattern means "one
# or more a, then b" and would not match the literal scope "a+b", so the
# post-delete check would report a credential gone while it was still stored.
secret_present() {
  sbx secret ls 2>/dev/null | awk -v n="$NAME" 'NR > 1 && $1 == n { found = 1 } END { exit !found }'
}

rollback() {
  printf '\n'
  step "Creation failed, rolling back"

  if [[ -d "$SEED" ]]; then
    note "removing seed clone $SEED"
    rm -rf "$SEED"
  fi

  # Attempted unconditionally rather than gated on a prior `secret ls`: the
  # store is written by the daemon, so a read immediately after `secret set`
  # can still show nothing and would skip the delete, leaving the credential.
  # Deleting something absent is harmless; the verify below is what reports.
  if (( ! NO_TOKEN )); then
    yes | sbx secret rm --sandbox "$NAME" github >/dev/null 2>&1 || true
    if secret_present; then
      note "WARNING: scoped secret survived rollback. Remove it with:"
      note "  sbx secret rm --sandbox $NAME github"
    else
      note "no staged secret left behind"
    fi
  fi
}

printf '\n'
step "Creating sandbox"
if ! run sbx create claude --clone --name "$NAME" \
  --kit "$CONFIG_KIT" \
  --kit "$RESEARCH_KIT" \
  "$SEED"; then
  rollback
  die "sandbox creation failed; nothing was left behind"
fi

if (( DRY_RUN )); then exit 0; fi

printf '\n'
step "Ready"
note "attach:            sbx run --name $NAME"
note "retrieve work:     git -C $SEED fetch sandbox-$NAME && git -C $SEED log sandbox-$NAME/main"
note "tear down:         research-sandbox --destroy $NAME"
