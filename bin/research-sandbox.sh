#!/usr/bin/env bash
#
# File:    research-sandbox.sh
# Created: 2026-08-22
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# requires: sbx
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
# The credential half of that last point is shared with project-sandbox and is
# written up in docs/sandbox-github-access.md, including why a ruleset rather
# than the token is what keeps the agent off the default branch.
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
ATTACH=0
WORKTREE=""
WORKTREE_SEEN=0
FORCE=0
DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: research-sandbox [options] [REPO]
       research-sandbox --attach [NAME] [--worktree NAME]
       research-sandbox --destroy NAME

Creates a sandbox for research and planning on a GitHub repo: full network
egress, a private clone on a container volume, and no host filesystem access.

REPO is owner/repo or a https://github.com/owner/repo URL. Omit it inside a
git checkout and it is read from that checkout's origin remote.

Options:
  -n, --name NAME       Sandbox name (default: research-<repo>).
  -r, --token-ref REF   1Password reference for the GitHub token, e.g.
                        op://Private/gh-research/credential. Stored scoped to
                        this sandbox only, so the global token is never used.
      --no-token        Create with no GitHub credential at all. Public repos
                        still clone; push and PR will not work.
  -a, --attach [NAME]   Open an agent in an existing sandbox. NAME defaults to
                        the name creation would derive from REPO or from the
                        checkout you are standing in. Every attach starts a new
                        agent; it never returns to one already running.
  -w, --worktree NAME   Attach with the agent working in .claude/worktrees/NAME
                        on branch worktree-NAME, so it does not share a working
                        tree with the agents already in the sandbox. Only valid
                        with --attach.
      --destroy NAME    Remove a research sandbox, its seed clone, and its
                        scoped secret.
  -f, --force           Re-clone the seed directory if it already exists.
  -y, --yes             Skip confirmation prompts.
      --dry-run         Print what would happen and exit.
  -h, --help            Show this help.

Environment:
  SBX_GH_TOKEN_REF_<OWNER>  Token reference for one repository owner, e.g.
                            SBX_GH_TOKEN_REF_MPORTNER. Owner upper-cased,
                            anything outside A-Z0-9 folded to _. Shared with
                            project-sandbox, so one per owner covers both.
  SBX_GH_TOKEN_REF          Fallback when no owner-specific one is set.
  RESEARCH_SEED_ROOT        Seed clone directory
                            (default ~/.local/state/sbx-research).
  SBX_CLAUDE_SUBSCRIPTION_TYPE
                            Plan name the sandbox banner should report (max,
                            pro, ...). Defaults to the plan on the host's own
                            account. sbx stages no plan of its own, so without
                            it the banner reads "Claude API".
  HERDR_ENV                 Set to 1 by herdr in a pane it manages. The attach
                            it prints then runs under argv0 "claude", which is
                            what makes herdr see the sandbox session as an
                            agent rather than an unidentified process.

A fine-grained token has one resource owner, so repos under a personal account
and repos under an organisation need separate tokens. Set one variable per
owner and the right one is chosen from the repo argument. --token-ref beats
both. After creation the token is checked from inside the sandbox: an
unreachable repo aborts, missing read permissions warn.

The credential model, the permission set the token needs, and why `gh pr
checks` cannot work from a fine-grained token are documented in
docs/sandbox-github-access.md.
EOF
}

# --worktree needs a name, and this is deliberately stricter than `claude`,
# which will happily invent one. Naming it here is what lets the launcher
# report the branch it lands on and warn about the tree it does not share, and
# a worktree the launcher cannot name is one it cannot say anything about.
# Kept in step with project-sandbox's flag of the same name.
take_worktree() {
  # -* rejected as well as empty: `--worktree --dry-run` would otherwise name a
  # worktree after the flag that followed it and swallow that flag silently.
  case "${1:-}" in
    ''|-*) die \
"--worktree needs a name, e.g. --worktree review-fixes" ;;
  esac
  WORKTREE="$1"
  WORKTREE_SEEN=1
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
    # The name is optional, so it cannot go through need_value: a bare --attach
    # derives the name the same way creation does. Only a following word that
    # is not itself an option is taken, which keeps `--attach --worktree fix`
    # from swallowing the flag after it as a sandbox name.
    -a|--attach)
      ATTACH=1
      if [[ -n "${2:-}" && "$2" != -* ]]; then NAME="$2"; shift; fi ;;
    -w|--worktree)  need_value "$@"; take_worktree "$2"; shift ;;
    --worktree=*)   take_worktree "${1#--worktree=}" ;;
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

# Creation cannot honour it: `claude --worktree` branches from HEAD inside the
# sandbox, and at creation time there is no sandbox and no HEAD to branch from.
if (( WORKTREE_SEEN )) && (( ! ATTACH )); then
  die \
"--worktree only applies when attaching, e.g.
  research-sandbox --attach ${NAME:-NAME} --worktree $WORKTREE"
fi

# Set here so the function below can report where the repo came from, and read
# by the preflight note in the create path.
REPO_SOURCE=""

# Falling back to the checkout you are standing in, which is what you almost
# always mean. Only the owner and repo are taken from it: the sandbox still
# gets a fresh clone from GitHub, never this working tree, so running the
# command from a dirty or half-rebased checkout changes nothing about what
# lands inside.
#
# Shared by create and attach. Attach needs it only to derive the default
# sandbox name, which is the same name creation would have chosen, so deriving
# it the same way is what keeps `research-sandbox` and `research-sandbox
# --attach` agreeing about which sandbox a checkout means.
derive_repo_arg() {
  [[ -z "${REPO_ARG:-}" ]] || return 0
  # Not a git directory is a usage error, same as before this fallback existed:
  # there is no argument and nothing to infer one from.
  origin_root="$(git_repo_root)" || { usage >&2; exit 2; }
  classify_origin "$origin_root"
  case "$ORIGIN_KIND" in
    https|ssh)
      REPO_ARG="$ORIGIN_URL"
      REPO_SOURCE="origin of $origin_root"
      ;;
    non-github)
      die \
"origin of $origin_root is not a github.com remote:
  $ORIGIN_URL
This sandbox clones from GitHub, so pass a REPO argument instead."
      ;;
    none)
      die \
"$origin_root has no origin remote to read the repository from.
Pass REPO explicitly, e.g. research-sandbox owner/repo."
      ;;
  esac
}

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

# --- attach -----------------------------------------------------------------

# Every attach starts a new agent. `sbx run` does not return to the one already
# in the sandbox, it adds another, and an agent outlives the pane it was opened
# in: closing the terminal detaches it and leaves it running. So this mode is
# how you get a second agent, and the count below is how you find out about the
# ones you have forgotten.
if (( ATTACH )); then
  if [[ -z "$NAME" ]]; then
    derive_repo_arg
    parse_repo_arg
    NAME="research-$repo"
  fi

  # owner/repo is a repository, not a sandbox name, and no sandbox name can
  # contain a slash. Caught before the lookup because `--attach owner/repo` is
  # the natural thing to type, and the generic "no sandbox named" below would
  # send you looking for a sandbox that was never going to be there.
  case "$NAME" in
    */*) die \
"'$NAME' is a repository, not a sandbox name.
Pass it as the REPO argument instead:
  research-sandbox $NAME --attach" ;;
  esac

  step "Attaching to $NAME"
  note "sandbox            $NAME"

  # `sbx ls -q` prints one name per line, so an exact whole-line match is
  # enough and avoids a substring hit on a longer name containing this one.
  # Matching project-sandbox, which decides create-or-attach the same way.
  if ! sbx ls -q 2>/dev/null | grep -qxF -- "$NAME"; then
    die \
"no sandbox named '$NAME'.
Create one with:      research-sandbox [REPO]
See what exists with: sbx ls"
  fi

  # Empty means the count could not be taken, which is not the same as none.
  AGENTS="$(agent_session_count)"
  if [[ -n "$AGENTS" ]]; then
    note "agents running     $AGENTS"
  elif ! command -v jq >/dev/null 2>&1; then
    # Named explicitly because it is the one cause with an obvious fix, the way
    # check_ruleset names it. Anything else is the sandbox not answering.
    note "agents running     unknown, jq is not installed on the host"
  else
    note "agents running     unknown, the sandbox did not answer"
  fi
  if [[ -n "$WORKTREE" ]]; then
    note "worktree           $WORKTREE (branch worktree-$WORKTREE)"
  fi

  # The tree is the thing worth warning about, not the second agent itself.
  # Two agents in one sandbox are fine and are the point of this mode; two
  # agents in one working tree overwrite each other's edits.
  #
  # Nothing is pre-created here, unlike project-sandbox, which adds the
  # worktree on the host and isolates its node_modules first. Both reasons for
  # that are absent: a --clone workspace lives on a container volume, so the
  # kit's node_modules isolation is inert, and the host seed clone is not the
  # tree the agent works in, so there is nothing here to pre-create.
  # Anything but a positive "nobody else is here" warns, so an unknown count
  # errs towards the warning rather than towards silence.
  if [[ -z "$WORKTREE" && "$AGENTS" != 0 ]]; then
    note "WARNING: this attach shares the working tree with any agent already"
    note "         running here, so their edits will collide. Pass --worktree"
    note "         NAME to give this one a tree of its own."
  fi

  # Built once, so the attach reported by --dry-run is the attach that runs.
  ATTACH_ARGS=()
  if [[ -n "$WORKTREE" ]]; then
    ATTACH_ARGS=(--worktree "$WORKTREE")
  fi

  if (( DRY_RUN )); then
    printf '    would run: %s\n' \
      "$(attach_command ${ATTACH_ARGS[@]+"${ATTACH_ARGS[@]}"})"
    exit 0
  fi

  exec_attach ${ATTACH_ARGS[@]+"${ATTACH_ARGS[@]}"}
fi

# --- resolve the repo -------------------------------------------------------

derive_repo_arg
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
if [[ -n "$REPO_SOURCE" ]]; then
  note "          read from the $REPO_SOURCE"
fi
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
"no GitHub token reference for owner '$owner'. Set SBX_GH_TOKEN_REF_$owner_key
for this owner, or SBX_GH_TOKEN_REF as a fallback, or pass --token-ref,
  e.g. --token-ref op://Private/gh-research/credential
Use --no-token to deliberately create a sandbox with no GitHub access.
Do not point this at your default token: this sandbox reads untrusted web
content, and the global token carries repo and admin rights."
fi

# Only the banner depends on this, so an unresolved plan is a note rather than a
# failure. It also sets PLAN_ENV for the create below. See
# resolve_subscription_type in lib/sandbox-launcher.sh for why the host keychain
# is not consulted.
report_subscription_type

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
  ${PLAN_ENV[@]+"${PLAN_ENV[@]}"} \
  --kit "$CONFIG_KIT" \
  --kit "$DEV_TOOLS_KIT" \
  --kit "$RESEARCH_KIT" \
  "$SEED"; then
  rollback
  die "sandbox creation failed; nothing was left behind"
fi

if (( DRY_RUN )); then exit 0; fi

# --- verify the staged token ------------------------------------------------

# Everything else about verification is the create-time default: the full
# permission set, and an unreachable repo aborts, because a research sandbox
# exists only for this repo and is worth nothing without it.
VERIFY_GIT_DIR="$SEED"
verify_token_access

printf '\n'
step "Checking the generated instructions"
check_generated_guidance

printf '\n'
step "Ready"
# --attach leads, because it is the form that picks the argv0 spoof for the
# shell it actually runs in and reports what is already in the sandbox. The
# raw sbx commands stay, since an attach is often pasted into a pane other
# than this one.
#
# Both raw spellings are printed, and neither is gated on this shell. Which one
# is right depends on where the session is attached from, and that is not known
# here: a sandbox created in a herdr pane is often attached from a different
# one, and one created in a plain terminal may well be attached inside herdr
# later. So the question HERDR_ENV answers here is not the question being
# asked, and the herdr form is printed as its own labelled line instead of
# replacing the plain one. project-sandbox has no such problem: it attaches
# itself, in the shell doing the asking.
#
# Both go through the shared builder, in a command substitution so setting
# HERDR_ENV for the call cannot leak past it. No arguments on purpose: this
# launcher has none to forward, and the hint is a command to run by hand.
note "attach:            research-sandbox --attach $NAME"
note "another agent:     research-sandbox --attach $NAME --worktree NAME"
# shellcheck disable=SC2119
note "raw attach:        $(HERDR_ENV=0 attach_command)"
# shellcheck disable=SC2119
note "in a herdr pane:   $(HERDR_ENV=1 attach_command)"
note "retrieve work:     git -C $SEED fetch sandbox-$NAME && git -C $SEED log sandbox-$NAME/main"
note "tear down:         research-sandbox --destroy $NAME"
