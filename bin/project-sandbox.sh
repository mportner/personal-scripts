#!/usr/bin/env bash
#
# File:    project-sandbox.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# requires: sbx
#
# Creates an sbx sandbox for development on a real checkout: the repository
# root bind-mounted, the default network policy, and a GitHub token scoped to
# this sandbox alone.
#
# The sibling of bin/research-sandbox.sh, sharing lib/sandbox-launcher.sh with
# it. What it exists for is that last point. `sbx run claude` already gives a
# sandbox dev-tools-kit and the supply-chain policy, but authenticates it with
# the GLOBAL github secret, which is a broad OAuth token. Research sandboxes
# were built specifically to avoid that, and there is no reason everyday
# development should not have the same narrow, owner-keyed credential.
#
# Two things deliberately do not carry over from the research launcher, and
# both follow from mounting the user's own files:
#
#   network     research-kit is NOT loaded. Its permissions.network.allow
#               ["**"] is sound only alongside the clone isolation; here the
#               agent can write the real working tree, so egress stays on the
#               default policy.
#   filesystem  the workspace is the checkout itself rather than a throwaway
#               clone, so nothing in the destroy path removes a directory. The
#               only thing it deletes is its own state file.
#
# Targets bash 3.2, the version macOS ships.
set -euo pipefail

# Resolved through symlinks: setup.sh installs this as ~/.local/bin/<name>, so
# BASH_SOURCE is the symlink and its dirname is the link directory, not the
# repo. See the matching comment in research-sandbox.sh for why the walk is by
# hand rather than `readlink -f`.
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

# Consumed by die() in lib/output.sh.
PROG="project-sandbox"
# shellcheck source=../lib/output.sh
source "$REPO_DIR/lib/output.sh"
# shellcheck source=../lib/sandbox-launcher.sh
source "$REPO_DIR/lib/sandbox-launcher.sh"

# Named to match RESEARCH_SEED_ROOT, which overrides the equivalent directory
# for the research launcher.
STATE_ROOT="${SBX_DEV_STATE_ROOT:-$HOME/.local/state/sbx-dev}"

# Left empty here on purpose. The environment defaults are resolved once the
# owner is known, so an owner-specific reference can outrank the generic one.
TOKEN_REF=""
TOKEN_REF_SOURCE=""
TOKEN_REF_EXPLICIT=0

# An unreachable repo never tears this sandbox down. It holds the user's own
# checkout, and the fix is to widen the token, not to rebuild the container.
UNREACHABLE_ACTION="unstage"

# Set by resolve_token_ref, and read by the no-reference diagnostic below.
# Initialised here so that diagnostic cannot trip over set -u if it is ever
# reached on a path where resolve_token_ref was not.
owner_key=""

NAME=""
NO_TOKEN=0
DESTROY=0
DRY_RUN=0
ASSUME_YES=0
PLAYWRIGHT=1
VERIFY=0
WORKTREE=""
WORKTREE_SEEN=0
REPO_SOURCE=""

usage() {
  cat <<'EOF'
Usage: project-sandbox [options] [-- AGENT_ARGS...]
       project-sandbox --destroy NAME

Creates a sandbox for development on the checkout you are standing in: the
repository root bind-mounted, the default network policy, and a GitHub token
scoped to this sandbox alone rather than the global one.

The first run creates the sandbox and exits. Run it again in the same checkout
to attach. The sandbox is named after the repository root's directory name, so
two checkouts of the same repository stay distinct.

Run from a subdirectory or a linked worktree and the repository root is
resolved and mounted, not the directory you happened to be in.

Options:
  -n, --name NAME       Sandbox name (default: the repository directory name).
  -r, --token-ref REF   1Password reference for the GitHub token, e.g.
                        op://Private/gh-dev/credential. Stored scoped to this
                        sandbox only, so the global token is never used.
      --no-token        Create with no GitHub credential at all.
  -w, --worktree NAME   Attach with the agent working in .claude/worktrees/NAME
                        on branch worktree-NAME, pre-created here so its
                        node_modules is isolated from the host's. Only valid
                        when attaching.
      --no-playwright   Skip Playwright's system libraries, halving creation
                        time. Leave them in if the project runs browser tests.
      --verify          Run the full permission check rather than the
                        reachability probe an attach settles for.
      --destroy NAME    Remove a sandbox, its scoped secret and its state file.
                        Never removes a directory.
  -y, --yes             Skip confirmation prompts.
      --dry-run         Print what would happen and exit.
  -h, --help            Show this help.

With no terminal to prompt on, questions are not asked at all. The ones that
only report what is about to happen are answered yes, so an unattended run
proceeds; anything that removes something or edits a committed file is answered
no. Either way the assumed answer is printed.

Anything after -- is passed to the agent. --worktree is lifted out of it and
handled here, in all of --worktree NAME, --worktree=NAME and -w NAME, because
a worktree the launcher does not know about is one it cannot isolate.

Environment:
  SBX_GH_TOKEN_REF_<OWNER>  Token reference for one repository owner, e.g.
                            SBX_GH_TOKEN_REF_MPORTNER. Owner upper-cased,
                            anything outside A-Z0-9 folded to _. Shared with
                            research-sandbox, so one per owner covers both.
  SBX_GH_TOKEN_REF          Fallback when no owner-specific one is set.
  SBX_DEV_STATE_ROOT        Preflight state directory
                            (default ~/.local/state/sbx-dev).
  SBX_CLAUDE_SUBSCRIPTION_TYPE
                            Plan name the sandbox banner should report (max,
                            pro, ...). Defaults to the plan on the host's own
                            account. sbx stages no plan of its own, so without
                            it the banner reads "Claude API".
  HERDR_ENV                 Set to 1 by herdr in a pane it manages. The attach
                            then runs under argv0 "claude", which is what makes
                            herdr see the sandbox session as an agent rather
                            than an unidentified process.

The owner comes from the checkout's origin remote, so there is nothing to pass.
A non-GitHub origin fails preflight, and a checkout with no origin needs
--no-token or an explicit --token-ref.

The credential model, the permission set and how the token reaches the sandbox
without ever being held there are documented in docs/sandbox-github-access.md.
EOF
}

# Every prompt goes through this. --yes answers yes; a stdin that is not a
# terminal cannot be asked at all, so it takes $2 as the answer rather than
# blocking on a question nobody can see.
#
# That answer is per prompt on purpose. A prompt that only reports what is
# about to happen takes "yes", so an unattended run proceeds instead of failing
# on a question it was never going to be shown. Anything that removes something
# or edits a committed file takes "no", which is what keeps an unattended
# --destroy from running unconfirmed.
confirm() {
  local reply
  if (( ASSUME_YES )); then return 0; fi
  if [[ ! -t 0 ]]; then
    # Say which way it went. The two answers lead to opposite outcomes, so a
    # log that records only the question having been skipped does not tell you
    # what the run actually did, which is precisely what an unattended run has
    # no other way of reporting.
    note "not asked (no terminal to prompt on), answering $2:"
    note "  $1"
    [[ "$2" == yes ]]
    return
  fi
  printf '\n%s [y/N] ' "$1"
  read -r reply || reply=n
  case "$reply" in
    [yY]*) return 0 ;;
    *)     return 1 ;;
  esac
}

# dev-tools-kit gives every bind-mounted node_modules a private directory on
# the container's own filesystem, but it does that in a startup command, over
# the workspace as it stood when the container started. A worktree added
# afterwards is invisible to it, so the same treatment is applied here by hand.
#
# Without it, installs inside the worktree resolve over virtiofs against the
# host's macOS tree: @esbuild/darwin-arm64 and friends cannot run on Linux, so
# every install re-resolves the whole tree and writes the result back onto the
# host, corrupting it in both directions. That is the failure dev-tools-kit
# exists to prevent, and a worktree is exactly where it would come back.
#
# Deliberately the same store and the same naming as that kit (the path
# relative to the workspace, slashes folded to underscores), so the two are
# idempotent with respect to each other: anything mounted here already reads as
# overlay rather than virtiofs when the kit's startup command re-runs on the
# next container start, and is skipped there.
#
# Unbounded depth, unlike the kit's maxdepth 4. A worktree already sits three
# levels down at .claude/worktrees/NAME, so a monorepo's own packages fall past
# that limit and would be left on the host tree.
isolate_worktree_node_modules() {
  step "Isolating node_modules under $WORKTREE_DIR"
  # WORKSPACE_DIR is the mount point inside the container, which sbx sets to
  # the same absolute path as the host checkout, so WORKTREE_DIR needs no
  # translation. Passed as an argument rather than interpolated into the
  # script, so a path with a quote or a space in it cannot reshape the command.
  # Single quotes throughout the block below are deliberate: every $ in it
  # has to reach the container's shell unexpanded, and the one value from
  # out here arrives as $1.
  # shellcheck disable=SC2016
  if sbx exec -u root "$NAME" -- sh -c '
      set -eu
      WT="$1"
      STORE=/var/lib/sbx-dev-tools
      [ -n "${WORKSPACE_DIR:-}" ] || exit 0
      [ "$(findmnt -no FSTYPE --target "$WORKSPACE_DIR" 2>/dev/null)" = virtiofs ] || exit 0
      mkdir -p "$STORE"

      mounted=0
      skipped=0
      MANIFESTS=$(mktemp)
      LIST=$(mktemp)

      # Candidates come from committed package.json files, not only from
      # directories that already exist: on a fresh worktree there is no
      # node_modules yet, so mounting over what is there would cover nothing
      # and the first install would land on the host tree.
      find "$WT" \( -name node_modules -o -name .git \) -prune \
           -o -name package.json -type f -print > "$MANIFESTS" 2>/dev/null || true
      while IFS= read -r manifest; do
        echo "${manifest%/package.json}/node_modules" >> "$LIST"
      done < "$MANIFESTS"

      # .pnpm-store belongs on the same filesystem as node_modules: pnpm
      # hardlinks out of it, which only works within one filesystem, so
      # leaving it behind turns every package into a full copy.
      echo "$WT/.pnpm-store" >> "$LIST"

      # Unioned in to catch any directory with no package.json beside it.
      find "$WT" \( -name node_modules -o -name .pnpm-store \) -type d -prune \
           >> "$LIST" 2>/dev/null || true

      sort -u "$LIST" > "$MANIFESTS"

      while IFS= read -r dir; do
        # The mountpoint has to exist first. This must come before the
        # filesystem test: findmnt --target prints nothing for a path that
        # does not exist rather than falling back to the parent mount, so
        # testing first skips every directory yet to be created.
        [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || continue

        # Idempotent: anything already isolated, whether by this launcher on an
        # earlier attach or by the kit at container start, reads as the
        # container filesystem rather than virtiofs. A second bind mount over
        # the same path would simply stack.
        if [ "$(findmnt -no FSTYPE --target "$dir" 2>/dev/null)" != virtiofs ]; then
          skipped=$(( skipped + 1 ))
          continue
        fi

        rel=$(echo "${dir#"$WORKSPACE_DIR"/}" | tr / _)
        [ -n "$rel" ] || rel=root

        back="$STORE/$rel"
        mkdir -p "$back"
        chown agent:agent "$back"

        if mount --bind "$back" "$dir" 2>/dev/null; then
          echo "    isolated $dir"
          mounted=$(( mounted + 1 ))
        else
          echo "    WARNING  could not isolate $dir" >&2
        fi
      done < "$MANIFESTS"

      # Says so rather than printing a banner and nothing else, which on a
      # re-attach is indistinguishable from the step having failed.
      echo "    $mounted newly isolated, $skipped already on the container filesystem"

      rm -f "$LIST" "$MANIFESTS"
    ' sh "$WORKTREE_DIR"; then
    :
  else
    note "WARNING: node_modules under the worktree was not isolated. Installs"
    note "         there will write to the host checkout over virtiofs."
  fi
}

# --- options ----------------------------------------------------------------
# Everything after -- belongs to the agent, except --worktree, which is lifted
# back out below.

# Why this launcher insists on a name, appended by the library to the message
# it shares with research-sandbox. A worktree we cannot name is one we cannot
# pre-create, and one the agent creates for itself gets no node_modules
# isolation at all, which is this launcher's concern alone.
WORKTREE_NAME_REASON="This is narrower than \`claude --worktree\` on purpose: the name is what lets
the launcher pre-create the worktree and isolate its node_modules, so one it
cannot name is one it cannot prepare."

while (( $# > 0 )); do
  # Both spellings of --worktree come from the launcher library, which reports
  # through WORKTREE_SHIFT how much of "$@" it consumed.
  if take_worktree_flag "$@"; then shift "$WORKTREE_SHIFT"; continue; fi
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
  e.g. --token-ref op://Private/gh-dev/credential
Use --no-token to create a sandbox with no GitHub access."
      TOKEN_REF="$2"; TOKEN_REF_EXPLICIT=1; shift ;;
    --no-token)     NO_TOKEN=1 ;;
    --no-playwright) PLAYWRIGHT=0 ;;
    --verify)       VERIFY=1 ;;
    --destroy)      need_value "$@"; DESTROY=1; NAME="$2"; shift ;;
    -y|--yes)       ASSUME_YES=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; break ;;
    -*)             printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    *)              printf 'Unexpected argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# Whatever survived the -- is the agent's, minus any --worktree spelling, which
# is normalised out here and re-added as a single canonical pair at launch.
# Passing it straight through would let claude create the worktree itself, and
# a worktree that appears after the container started has no isolation.
AGENT_ARGS=()
while (( $# > 0 )); do
  if take_worktree_flag "$@"; then shift "$WORKTREE_SHIFT"; continue; fi
  AGENT_ARGS+=("$1")
  shift
done

command -v sbx >/dev/null 2>&1 || die "sbx is not installed"
command -v git >/dev/null 2>&1 || die "git is not installed"

# --- destroy ----------------------------------------------------------------
# Ahead of any repository resolution, so a sandbox can be torn down from
# anywhere, including after its checkout has been moved or deleted.

if (( DESTROY )); then
  [[ -n "$NAME" ]] || die "--destroy needs a sandbox name"
  step "Destroying project sandbox $NAME"
  note "sandbox      $NAME"
  note "scoped github secret, if any"
  note "state file   $STATE_ROOT/$NAME.state"
  note "your checkout is NOT touched; nothing here removes a directory"

  # Milder than the research launcher's warning, and accurately so: commits
  # made in here landed in the bind-mounted checkout, not inside the container.
  # What does die with the sandbox is its container-side state, which is where
  # the Linux node_modules lives.
  if (( ! DRY_RUN )); then
    if ! confirm "Remove these? The sandbox's own node_modules and caches are lost." no; then
      die "cancelled (use --yes to skip this prompt)"
    fi
  fi

  printf '\n'
  run sbx rm "$NAME" -f || note "sandbox $NAME not found, continuing"

  # Leaving this behind would silently apply to any future sandbox that
  # happens to reuse the name.
  remove_scoped_secret

  # rm -f, never rm -rf: the only path this script may delete is its own state
  # file, and a plain file needs no recursion. See the header.
  run rm -f "$STATE_ROOT/$NAME.state"

  step "Done"
  exit 0
fi

# --- resolve the checkout ---------------------------------------------------

REPO_ROOT="$(git_repo_root)" || die \
"not inside a git repository.
project-sandbox mounts the repository root, which it reads from the checkout
you run it in. cd into one first."

classify_origin "$REPO_ROOT"
ORIGIN_WARNING=""
ORIGIN_IS_SSH=0
case "$ORIGIN_KIND" in
  https)
    REPO_ARG="$ORIGIN_URL"
    REPO_SOURCE="origin of $REPO_ROOT"
    ;;
  ssh)
    REPO_ARG="$ORIGIN_URL"
    REPO_SOURCE="origin of $REPO_ROOT"
    # The owner parses fine, but the remote will not work from inside. GitHub
    # auth there is the egress proxy substituting a token into HTTPS traffic,
    # and the sandbox has no SSH key, so a push over this origin fails on
    # authentication rather than on permissions. The warning itself is built
    # after parse_repo_arg below, since it names the HTTPS spelling to switch
    # to and that needs the owner and repo picked out of the URL first.
    ORIGIN_IS_SSH=1
    ;;
  non-github)
    # --no-token has to be a working answer here and not merely a suggestion:
    # the sandbox is perfectly usable without a GitHub credential, and a
    # Bitbucket checkout has no token that could fit one. An explicit
    # --token-ref is honoured too, since the caller has then said which
    # credential they mean despite the origin.
    if (( ! NO_TOKEN )) && (( ! TOKEN_REF_EXPLICIT )); then
      die \
"origin of $REPO_ROOT is not a github.com remote:
  $ORIGIN_URL
There is no GitHub token that fits it. Use --no-token to create a sandbox with
no GitHub credential at all."
    fi
    ;;
  none)
    if (( ! NO_TOKEN )) && (( ! TOKEN_REF_EXPLICIT )); then
      die \
"$REPO_ROOT has no origin remote, so there is no owner to pick a token for.
Pass --token-ref to choose one explicitly, or --no-token to create a sandbox
with no GitHub credential at all."
    fi
    ;;
esac

if [[ -n "${REPO_ARG:-}" ]]; then
  parse_repo_arg
  resolve_token_ref
  if (( ORIGIN_IS_SSH )); then
    ORIGIN_WARNING="origin is an SSH remote and the sandbox has no key for it:
             GitHub auth in there is the egress proxy substituting a token
             into HTTPS traffic. If push fails inside, switch origin to
             https://github.com/$owner/$repo.git"
  fi
else
  # --no-token or an explicit --token-ref, in a checkout whose origin gives no
  # GitHub owner. There is nothing to key a token on and no repo for the probes
  # to reach, so verification and the ruleset check are both skipped below.
  owner=""
  repo=""
  # resolve_token_ref is what normally records this, and it is not reached
  # without an owner. Without it preflight prints an empty "via" line.
  if (( TOKEN_REF_EXPLICIT )); then
    TOKEN_REF_SOURCE="--token-ref"
  fi
fi

# The sandbox name comes from the directory rather than the repository, which
# is what keeps two checkouts of the same repository apart. sbx accepts letters,
# numbers, hyphens and periods only, so anything else is folded to a hyphen
# rather than handed over to fail at creation.
if [[ -z "$NAME" ]]; then
  NAME="$(printf '%s' "${REPO_ROOT##*/}" | LC_ALL=C tr -c 'A-Za-z0-9.-' '-')"
fi
case "$NAME" in
  [A-Za-z0-9]?*) ;;
  *) die "cannot derive a usable sandbox name from $REPO_ROOT; pass --name" ;;
esac

STATE_FILE="$STATE_ROOT/$NAME.state"

if sandbox_exists; then
  MODE=attach
else
  MODE=create
fi

# The worktree has to be added to the host checkout and then isolated inside a
# container that is already running, so there is nothing to add it to until the
# sandbox exists. Rather than quietly creating first and applying the flag
# after, which hides a two-step operation behind one command, say so.
if (( WORKTREE_SEEN )) && [[ "$MODE" == create ]]; then
  die \
"--worktree only applies when attaching, and no sandbox named '$NAME' exists yet.
Run it twice:
  project-sandbox
  project-sandbox --worktree $WORKTREE"
fi

# --- preflight --------------------------------------------------------------

step "Preflight"
[[ -d "$CONFIG_KIT" ]]    || die "missing kit: $CONFIG_KIT"
[[ -d "$DEV_TOOLS_KIT" ]] || die "missing kit: $DEV_TOOLS_KIT"
note "kits      $CONFIG_KIT"
note "          $DEV_TOOLS_KIT"
note "root      $REPO_ROOT"
if [[ -n "$owner" ]]; then
  note "repo      $owner/$repo"
  note "          read from the $REPO_SOURCE"
fi
note "sandbox   $NAME ($MODE)"
if [[ -n "$ORIGIN_WARNING" ]]; then
  printf '    WARNING  %s\n' "$ORIGIN_WARNING" >&2
fi

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
  e.g. --token-ref op://Private/gh-dev/credential
Use --no-token to deliberately create a sandbox with no GitHub access.
The global token is not a fallback here: keeping it out of development
sandboxes is the whole reason this command exists."
fi

# Only the banner depends on this, so an unresolved plan is a note rather than a
# failure. It also sets PLAN_ENV for the create below. See
# resolve_subscription_type in lib/sandbox-launcher.sh for why the host keychain
# is not consulted.
report_subscription_type

# A global secret is inherited by any sandbox that has none of its own, which
# makes the narrow token above a courtesy rather than a boundary. Reported
# rather than deleted, because it is shared state and other sandboxes may still
# be relying on it.
if global_secret_present; then
  printf '    WARNING  a global github secret is stored, and any sandbox without\n' >&2
  printf '             one of its own inherits it. This launcher exists to keep a\n' >&2
  printf '             broad token out of development sandboxes, so the global one\n' >&2
  printf '             should not be there at all. Remove it with:\n' >&2
  printf '               sbx secret rm github\n' >&2
fi

if [[ -n "$owner" ]]; then
  check_ruleset
fi

# --- what the sandbox is about to be handed ---------------------------------
# The whole checkout is bind-mounted, gitignored files included, so `git status`
# alone does not show what the agent will be able to read.

# Findings, one per line, as a stable set: printed for the user and compared
# against the last run's set to decide whether an attach needs to ask again.
scan_findings() {
  local entry base
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
    printf 'dirty   uncommitted changes; claude --worktree branches from HEAD, so\n'
    printf '        they will not be in the worktree\n'
  fi
  # NUL-separated, because porcelain v1 quotes and escapes any path holding a
  # space or a non-ASCII byte, and a quoted path matches none of the patterns
  # below. Ignored directories come back collapsed with a trailing slash, so a
  # node_modules tree is one entry rather than thousands.
  while IFS= read -r -d '' entry; do
    case "$entry" in
      '!! '*) entry="${entry#!! }" ;;
      *) continue ;;
    esac
    base="${entry%/}"
    base="${base##*/}"
    case "$base" in
      .env*|*.pem|*.key|credentials*)
        printf 'secret  %s\n' "$entry"
        ;;
    esac
  done < <(git -C "$REPO_ROOT" status --porcelain -z --ignored 2>/dev/null || true)
}

FINDINGS="$(scan_findings)"
PREVIOUS=""
if [[ -f "$STATE_FILE" ]]; then
  PREVIOUS="$(cat "$STATE_FILE")"
fi

# On create everything is new, so everything is worth confirming. On attach only
# a change is: re-reading the same three .env files aloud at every attach is how
# a prompt stops being read.
if [[ -n "$FINDINGS" ]] && { [[ "$MODE" == create ]] || [[ "$FINDINGS" != "$PREVIOUS" ]]; }; then
  printf '\n'
  step "Preflight findings"
  if [[ "$MODE" == attach ]]; then
    note "these have changed since the last attach"
  fi
  printf '%s\n' "$FINDINGS" | sed 's/^/    /'
  if (( ! DRY_RUN )); then
    if ! confirm "Continue with the checkout mounted as it stands?" yes; then
      die "cancelled (use --yes to skip this prompt)"
    fi
  fi
fi

# .claude/worktrees is where `claude --worktree` puts working trees. Left
# untracked they show up as noise in the very checkout this is meant to keep
# clean, and `git status` stops being usable. Offered rather than done, because
# .gitignore is a committed file and belongs to the user.
if ! git -C "$REPO_ROOT" check-ignore -q .claude/worktrees/ 2>/dev/null; then
  if (( DRY_RUN )); then
    note "would offer to add .claude/worktrees/ to $REPO_ROOT/.gitignore"
  elif confirm "Add .claude/worktrees/ to $REPO_ROOT/.gitignore?" no; then
    # Single-quoted so the backticks land in .gitignore as text rather than
    # being read as a command substitution.
    # shellcheck disable=SC2016
    printf '\n# Working trees created by `claude --worktree`\n.claude/worktrees/\n' \
      >> "$REPO_ROOT/.gitignore"
    note "appended .claude/worktrees/ to $REPO_ROOT/.gitignore"
  else
    note "WARNING: .claude/worktrees/ is not gitignored, so any worktree will"
    note "         show as untracked in $REPO_ROOT"
  fi
fi

if (( DRY_RUN )); then
  printf '\n'
  step "Dry run, nothing was created"
fi

# --- create -----------------------------------------------------------------

if [[ "$MODE" == create ]]; then
  # Staging first is the point: a secret added after creation would leave a
  # window in which the sandbox held the global token.
  if (( ! NO_TOKEN )); then
    stage_scoped_secret
  fi

  printf '\n'
  step "Creating sandbox"
  # No --clone and no research-kit: the workspace is the checkout itself, and
  # the open-egress policy is only sound alongside clone isolation.
  if ! run sbx create claude --name "$NAME" \
    -e "SBX_DEV_TOOLS_PLAYWRIGHT=$PLAYWRIGHT" \
    ${PLAN_ENV[@]+"${PLAN_ENV[@]}"} \
    --kit "$CONFIG_KIT" \
    --kit "$DEV_TOOLS_KIT" \
    "$REPO_ROOT"; then
    rollback
    die "sandbox creation failed; nothing was left behind"
  fi

  if (( DRY_RUN )); then exit 0; fi

  # Full on create, whatever --verify says: this is the one moment the whole
  # permission set is worth spending four round trips on.
  VERIFY_MODE="full"
  VERIFY_GIT_DIR="$REPO_ROOT"
  VERIFIED=1
  if ! verify_token_access; then VERIFIED=0; fi

  printf '\n'
  step "Checking the generated instructions"
  check_generated_guidance

  mkdir -p "$STATE_ROOT"
  printf '%s\n' "$FINDINGS" > "$STATE_FILE"

  printf '\n'
  if (( VERIFIED )); then
    step "Ready"
  else
    # The sandbox itself is fine and worth keeping; only its GitHub credential
    # is not, and verification has just removed it. Printing "Ready" over the
    # top of that ERROR block is how the ERROR block goes unread.
    step "Created, but with no working GitHub credential"
    note "fix the token and run this again to stage it"
  fi
  note "attach:            project-sandbox"
  note "attach on a branch: project-sandbox --worktree NAME"
  note "tear down:         project-sandbox --destroy $NAME"
  exit 0
fi

# --- attach -----------------------------------------------------------------

# What the agent is started with: the worktree this launcher handles itself
# rather than passing through, then whatever followed --.
build_attach_args ${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"}

if (( DRY_RUN )); then
  # The rest of this path talks to a live container, so there is nothing
  # further to simulate usefully.
  if [[ -n "$WORKTREE" ]]; then
    printf '    would prepare worktree %s on branch worktree-%s\n' "$WORKTREE" "$WORKTREE"
  fi
  printf '    would run: %s\n' \
    "$(attach_command ${ATTACH_ARGS[@]+"${ATTACH_ARGS[@]}"})"
  exit 0
fi

# The scoped secret is staged at creation, but verification removes it when the
# token cannot reach the repo, and --destroy is not the only way it can go
# missing. Re-staging here is what makes the fix-the-token-and-re-run advice
# that verification prints actually work.
if (( ! NO_TOKEN )) && ! secret_present; then
  stage_scoped_secret
fi

if [[ -n "$WORKTREE" ]]; then
  WORKTREE_DIR="$REPO_ROOT/.claude/worktrees/$WORKTREE"
  WORKTREE_BRANCH="worktree-$WORKTREE"

  printf '\n'
  step "Preparing worktree $WORKTREE"

  # `claude --worktree NAME` puts the tree at .claude/worktrees/NAME on branch
  # worktree-NAME, based on the current HEAD, and locks it for the session.
  # That path is hardcoded in the binary (verified against claude 2.1.231) and
  # is not configurable, which is what makes pre-creating it work: claude
  # reuses a worktree that is already there rather than erroring.
  #
  # Pre-creating it is the whole point. dev-tools-kit isolates node_modules at
  # container start, so a worktree that appears mid-session gets none: its
  # installs resolve over virtiofs against the host's macOS tree, which is both
  # slow and what corrupted that tree before the kit existed.
  BRANCH_EXISTED=0
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$WORKTREE_BRANCH"; then
    BRANCH_EXISTED=1
    note "attached to the existing branch $WORKTREE_BRANCH, rather than creating"
    note "it from HEAD, so it carries whatever was left on it last time"
    if ! confirm "Continue on $WORKTREE_BRANCH?" yes; then
      die "cancelled (use --yes to skip this prompt)"
    fi
  fi

  if [[ -d "$WORKTREE_DIR" ]]; then
    # A directory git has no worktree registered for is not one, however much
    # it looks like it: a leftover from a removed worktree, or an unrelated
    # directory that happens to sit at the path. `claude --worktree` would try
    # to create a worktree there and fail, and isolating it first would mount
    # over files nothing is managing. Reported rather than removed, because it
    # may hold work and this script does not delete directories.
    if ! git -C "$REPO_ROOT" worktree list --porcelain \
         | grep -qxF "worktree $WORKTREE_DIR"; then
      die \
"$WORKTREE_DIR exists but git has no worktree registered there.
Look at what is in it, then either remove it or run:
  git -C $REPO_ROOT worktree prune"
    fi
    note "reusing the worktree already at $WORKTREE_DIR"
  elif (( BRANCH_EXISTED )); then
    git -C "$REPO_ROOT" worktree add "$WORKTREE_DIR" "$WORKTREE_BRANCH" \
      || die "could not add a worktree at $WORKTREE_DIR"
  else
    note "creating $WORKTREE_DIR on $WORKTREE_BRANCH from $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    git -C "$REPO_ROOT" worktree add "$WORKTREE_DIR" -b "$WORKTREE_BRANCH" \
      || die "could not add a worktree at $WORKTREE_DIR"
  fi

  isolate_worktree_node_modules
fi

# Reachability only unless asked for more. Revocation and rescoping both show
# up on the first probe, while the permission set moves only when the token is
# edited, so re-running the other three at every attach spends round trips
# reprinting the last answer.
if [[ -n "$owner" ]]; then
  if (( VERIFY )); then VERIFY_MODE="full"; else VERIFY_MODE="reachable"; fi
  VERIFY_GIT_DIR="$REPO_ROOT"
  # Stopping here rather than launching, unlike on create where nothing follows
  # anyway. The scoped secret has just been removed, so the session would open
  # with no GitHub access at all, and dropping straight into an interactive
  # agent is how that diagnostic goes unread until an hour of work has gone by.
  if ! verify_token_access; then
    printf '\n' >&2
    printf '    Not attaching. The sandbox is still there: fix the token and run\n' >&2
    printf '    this again, or attach without GitHub access using --no-token.\n' >&2
    exit 1
  fi
fi

mkdir -p "$STATE_ROOT"
printf '%s\n' "$FINDINGS" > "$STATE_FILE"

printf '\n'
step "Attaching"

exec_attach ${ATTACH_ARGS[@]+"${ATTACH_ARGS[@]}"}
