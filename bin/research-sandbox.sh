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
# dev-tools-kit rides along for two reasons. The obvious one is that research
# leans on pnpm: `pnpm view` and `pnpm why` are how you answer a question about
# a dependency, and the base image has no pnpm at all. The less obvious one
# matters more. dev-tools-kit is what carries minimumReleaseAge,
# minimumReleaseAgeStrict and blockExoticSubdeps into a sandbox; without it,
# the one sandbox with unrestricted egress reading untrusted web content is
# also the only one installing packages with no release-age window. Its
# node_modules isolation is inert here, since that only acts on bind-mounted
# (virtiofs) paths and a --clone workspace is already on a container volume.
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
DEV_TOOLS_KIT="$REPO_DIR/dev-tools-kit"
RESEARCH_KIT="$REPO_DIR/research-kit"

# Consumed by die() in lib/output.sh.
PROG="research-sandbox"
# shellcheck source=../lib/output.sh
source "$REPO_DIR/lib/output.sh"
# shellcheck source=../lib/sandbox-launcher.sh
source "$REPO_DIR/lib/sandbox-launcher.sh"

SEED_ROOT="${RESEARCH_SEED_ROOT:-$HOME/.local/state/sbx-research}"
# Left empty here on purpose. The environment defaults are resolved once the
# owner is known, so an owner-specific reference can outrank the generic one.
TOKEN_REF=""
TOKEN_REF_SOURCE=""
TOKEN_REF_EXPLICIT=0

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
  RESEARCH_GH_TOKEN_REF_<OWNER>  Token reference for one repository owner, e.g.
                                 RESEARCH_GH_TOKEN_REF_MPORTNER. Owner
                                 upper-cased, anything outside A-Z0-9 to _.
  RESEARCH_GH_TOKEN_REF          Fallback when no owner-specific one is set.
  RESEARCH_SEED_ROOT             Seed clone directory
                                 (default ~/.local/state/sbx-research).

A fine-grained token has one resource owner, so repos under a personal account
and repos under an organisation need separate tokens. Set one variable per
owner and the right one is chosen from the repo argument. --token-ref beats
both. After creation the token is checked from inside the sandbox: an
unreachable repo aborts, missing read permissions warn.

The token needs these permissions on the repos you want researched:

Levels are the labels GitHub's own token UI uses, so they can be selected
verbatim. Read and write always implies read; the reason each one needs write
is named rather than left to inference.

  Metadata          Read-only        mandatory, selected for you
  Contents          Read and write   read to clone, write to push
  Pull requests     Read and write   write to create, review and merge
  Issues            Read and write   write to file follow-ups and set labels
  Commit statuses   Read-only        checks posted as a commit status
  Actions           Read-only        gh run view, job logs, and reading CI
  Workflows         Read and write   write to push under .github/workflows

There is no Checks permission for fine-grained tokens, only for GitHub Apps,
so `gh pr checks` cannot work from one: it resolves statusCheckRollup, which
reaches the Checks API and answers 403. Read CI through the Actions API:

  gh api repos/OWNER/REPO/actions/runs?head_sha=SHA \
    --jq '.workflow_runs[] | "\(.name): \(.status)/\(.conclusion)"'

Do not grant Administration. Branch protection comes from the repo's ruleset,
not the token, and a token that can edit the ruleset can remove its own guard.
EOF
}

run() {
  if (( DRY_RUN )); then
    printf '    would run: %s\n' "$*"
    return 0
  fi
  "$@"
}

while (( $# > 0 )); do
  case "$1" in
    -n|--name)      need_value "$@"; NAME="$2"; shift ;;
    -r|--token-ref)
      need_value "$@"
      # An empty value would suppress the owner-keyed lookup and then fall
      # through to the no-reference diagnostic, which advises setting an
      # environment variable that may already be set and is being ignored
      # precisely because this flag was passed. Reject it here instead.
      [[ -n "$2" ]] || die \
"--token-ref needs a non-empty 1Password reference,
  e.g. --token-ref op://Private/gh-research/credential
Use --no-token to create a sandbox with no GitHub access."
      TOKEN_REF="$2"; TOKEN_REF_EXPLICIT=1; shift ;;
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

parse_repo_arg

# Picked by owner rather than making the caller remember which default is
# exported: the seed clone below runs on the host with the host's own
# credentials, and so does the ruleset check, so a mismatched token is not
# caught until the agent tries to push from inside the sandbox, long after the
# work is done.
resolve_token_ref

# Always HTTPS, even when the caller passed an SSH URL. This is load-bearing,
# not a normalisation nicety: the sandbox inherits origin from this seed clone,
# and its GitHub auth is the sbx proxy injecting an Authorization header into
# HTTPS traffic. An SSH origin would give the sandbox a remote it has no key
# for, breaking push and `gh pr create` inside it.
CLONE_URL="https://github.com/$owner/$repo.git"
NAME="${NAME:-research-$repo}"
SEED="$SEED_ROOT/$NAME"

# --- preflight --------------------------------------------------------------

step "Preflight"
[[ -d "$CONFIG_KIT" ]]    || die "missing kit: $CONFIG_KIT"
[[ -d "$DEV_TOOLS_KIT" ]] || die "missing kit: $DEV_TOOLS_KIT"
[[ -d "$RESEARCH_KIT" ]]  || die "missing kit: $RESEARCH_KIT"
note "kits      $CONFIG_KIT"
note "          $DEV_TOOLS_KIT"
note "          $RESEARCH_KIT"
note "repo      $owner/$repo"
note "sandbox   $NAME"
note "seed      $SEED"

if (( NO_TOKEN )); then
  note "token     none (--no-token): push and PR will not work"
elif [[ -n "$TOKEN_REF" ]]; then
  case "$TOKEN_REF" in
    op://*) check_op_installed ;;
  esac
  note "token     $TOKEN_REF"
  note "          via $TOKEN_REF_SOURCE, scoped to this sandbox"
else
  die \
"no GitHub token reference for owner '$owner'. Set RESEARCH_GH_TOKEN_REF_$owner_key
for this owner, or RESEARCH_GH_TOKEN_REF as a fallback, or pass --token-ref,
  e.g. --token-ref op://Private/gh-research/credential
Use --no-token to deliberately create a sandbox with no GitHub access.
Do not point this at your default token: this sandbox reads untrusted web
content, and the global token carries repo and admin rights."
fi

# --- warn when the default branch is unprotected ----------------------------
check_ruleset

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
  stage_scoped_secret
fi

# --- create -----------------------------------------------------------------

printf '\n'
step "Creating sandbox"
# SBX_DEV_TOOLS_PLAYWRIGHT=0 halves the creation time (roughly 30s to 15s) by
# skipping the browser system libraries. Research sandboxes read and reason
# about code; they do not drive a browser.
if ! run sbx create claude --clone --name "$NAME" \
  -e SBX_DEV_TOOLS_PLAYWRIGHT=0 \
  --kit "$CONFIG_KIT" \
  --kit "$DEV_TOOLS_KIT" \
  --kit "$RESEARCH_KIT" \
  "$SEED"; then
  rollback
  die "sandbox creation failed; nothing was left behind"
fi

if (( DRY_RUN )); then exit 0; fi

# --- verify the staged token ------------------------------------------------

verify_token_access

printf '\n'
step "Ready"
note "attach:            sbx run --name $NAME"
note "retrieve work:     git -C $SEED fetch sandbox-$NAME && git -C $SEED log sandbox-$NAME/main"
note "tear down:         research-sandbox --destroy $NAME"
