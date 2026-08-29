#
# File:    sandbox-launcher.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Sandbox and GitHub machinery shared by every sbx launcher in bin/: repo
# argument parsing, deriving the repo from a checkout's origin, owner-scoped
# token reference resolution, the op preflight, sandbox-scoped secret staging
# and removal, its rollback, the ruleset check, post-create token verification,
# and resolving the Claude plan name the sandbox should report.
#
# These functions operate on globals their caller sets (REPO_ARG, NAME,
# SEED, TOKEN_REF, TOKEN_REF_EXPLICIT, TOKEN_REF_SOURCE, NO_TOKEN, DRY_RUN,
# VERIFY_MODE, UNREACHABLE_ACTION, ...) rather than taking parameters, matching
# the flat, global-variable style the rest of this repo already uses for these
# scripts. They also call the caller's own run(), so staging still honours
# --dry-run.
#
# This file defines functions only. It must be SOURCED, not executed, and it
# depends on lib/output.sh (die, note, step) being sourced first; see that
# file for why both have no shebang and are not executable.

# Parses REPO_ARG (owner/repo, an https://github.com/... URL, or a
# git@github.com:... URL) into owner and repo. Dies on anything else.
parse_repo_arg() {
  local slug
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
}

# Prints the root of the checkout containing the current directory, or fails
# when there is no repository there.
#
# Derived from --git-common-dir rather than --show-toplevel, which reports the
# linked worktree when run from inside one. The worktree is the wrong thing to
# hand a sandbox: its .git is a file pointing back into the main checkout's
# object store, so mounting the worktree alone gives the container a repository
# with no objects in it. The common directory is the main checkout's .git in
# both cases, so its parent is the root we want either way.
#
# Made absolute by hand rather than with --path-format=absolute, which git only
# gained in 2.31: --git-common-dir answers a bare ".git" when the cwd is the top
# of the tree, and dirname of that is "." rather than the repository.
git_repo_root() {
  local common
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$common" ]] || return 1
  case "$common" in
    /*) ;;
    *)  common="$(pwd -P)/$common" ;;
  esac
  (cd -- "$(dirname -- "$common")" && pwd -P) 2>/dev/null || return 1
}

# Classifies the origin remote of the checkout at $1, so callers can derive the
# repo from the working directory instead of being told it. Sets ORIGIN_URL and
# ORIGIN_KIND, the latter to one of:
#
#   https       a github.com HTTPS remote; ORIGIN_URL feeds parse_repo_arg
#   ssh         a github.com SSH remote, normalised to the scp-like form so
#               parse_repo_arg takes it. The owner parses fine, but the sandbox
#               authenticates by the proxy substituting a token into HTTPS
#               traffic and has no key, so callers warn about the mismatch
#   non-github  some other forge. There is no GitHub token that fits, so this
#               is a preflight failure rather than a warning
#   none        no origin at all, so there is nothing to derive an owner from
#
# ssh:// is folded into the scp-like spelling rather than given parse_repo_arg a
# third case: the two are the same remote written two ways, and every caller
# treats them identically.
# ORIGIN_KIND is read by the sourcing launcher, which shellcheck cannot see
# when it lints this file on its own.
# shellcheck disable=SC2034
classify_origin() {
  ORIGIN_URL="$(git -C "$1" remote get-url origin 2>/dev/null || printf '')"
  case "$ORIGIN_URL" in
    '')                     ORIGIN_KIND=none ;;
    https://github.com/*)   ORIGIN_KIND=https ;;
    git@github.com:*)       ORIGIN_KIND=ssh ;;
    ssh://git@github.com/*)
      ORIGIN_KIND=ssh
      ORIGIN_URL="git@github.com:${ORIGIN_URL#ssh://git@github.com/}"
      ;;
    *)                      ORIGIN_KIND=non-github ;;
  esac
}

# A fine-grained token has exactly one resource owner, so a personal account
# and an organisation need separate tokens. Sets owner_key, and TOKEN_REF plus
# TOKEN_REF_SOURCE when one is found.
#
# Precedence: --token-ref (TOKEN_REF_EXPLICIT, set by the caller's option
# parsing), then SBX_GH_TOKEN_REF_<OWNER>, then SBX_GH_TOKEN_REF. The owner is
# upper-cased with anything outside A-Z0-9 folded to _, so mportner becomes
# SBX_GH_TOKEN_REF_MPORTNER.
#
# Named for the sandbox rather than for research: every launcher in bin/ reads
# the same variables, so one token reference per owner covers both. There is no
# compatibility shim for the old RESEARCH_ spelling on purpose. A silent
# fallback is how you end up with two half-configured sets of variables and no
# idea which one is live, and the entire user population is one person editing
# two lines of a shell rc file.
resolve_token_ref() {
  local owner_var
  owner_key="$(printf '%s' "$owner" | LC_ALL=C tr '[:lower:]' '[:upper:]' \
    | LC_ALL=C tr -c 'A-Z0-9' '_')"
  if (( TOKEN_REF_EXPLICIT )); then
    TOKEN_REF_SOURCE="--token-ref"
  else
    owner_var="SBX_GH_TOKEN_REF_$owner_key"
    if [[ -n "${!owner_var:-}" ]]; then
      TOKEN_REF="${!owner_var}"
      TOKEN_REF_SOURCE="$owner_var"
    elif [[ -n "${SBX_GH_TOKEN_REF:-}" ]]; then
      TOKEN_REF="$SBX_GH_TOKEN_REF"
      TOKEN_REF_SOURCE="SBX_GH_TOKEN_REF"
    fi
  fi
}

# Only relevant once a TOKEN_REF has been chosen; callers gate this on the
# op:// scheme themselves, since a plain-text reference needs no CLI at all.
check_op_installed() {
  command -v op >/dev/null 2>&1 || die \
"op is not installed, so the 1Password reference cannot be resolved.
  brew install 1password-cli
then enable 'Integrate with 1Password CLI' in the 1Password app's Developer
settings. Or pass --no-token to create a sandbox with no GitHub credential."
}

# Exact string compare rather than a regex: sandbox names may contain periods
# and plus signs, which are ERE metacharacters. "a+b" as a pattern means "one
# or more a, then b" and would not match the literal scope "a+b", so the
# post-delete check would report a credential gone while it was still stored.
#
# The type and name columns are matched as well as the scope. A sandbox may
# hold secrets for other services, and callers here all mean the github one
# specifically: without this, an unrelated scoped secret makes the post-delete
# check report a github credential that is not there, and makes the re-stage
# check skip staging one that is missing.
secret_present() {
  sbx secret ls 2>/dev/null | awk -v n="$NAME" 'NR > 1 && $1 == n && $2 == "service" && $3 == "github" { found = 1 } END { exit !found }'
}

# The store's global row, which is the credential a sandbox falls back to when
# nothing is scoped to it. Same exact-string compare as secret_present, for the
# same reason; the scope column reads "(global)" literally.
global_secret_present() {
  sbx secret ls 2>/dev/null | awk 'NR > 1 && $1 == "(global)" && $2 == "service" && $3 == "github" { found = 1 } END { exit !found }'
}

# Removes the sandbox-scoped github secret and reports whether it survived.
#
# `yes |` feeds the confirmation prompt, but the pipeline exits non-zero even
# when the delete succeeds, so its status says nothing. The store is read
# afterwards instead: this is the step that has to be trustworthy, since a
# leftover token would silently apply to a later sandbox that reused the name.
#
# Attempted unconditionally rather than gated on a prior `secret ls`: the store
# is written by the daemon, so a read immediately after `secret set` can still
# show nothing and would skip the delete, leaving the credential. Deleting
# something absent is harmless; the check afterwards is what reports.
#
# Not routed through the caller's run(): the delete has to be attempted and its
# result read back, which run() cannot express, so --dry-run is handled here.
remove_scoped_secret() {
  if (( DRY_RUN )); then
    printf '    would run: sbx secret rm --sandbox %s github\n' "$NAME"
    return 0
  fi
  yes | sbx secret rm --sandbox "$NAME" github >/dev/null 2>&1 || true
  if secret_present; then
    note "WARNING: scoped secret still present. Remove it with:"
    note "  sbx secret rm --sandbox $NAME github"
  else
    note "no scoped secret left behind"
  fi
}

# Calls the caller's own run(), so this still honours --dry-run.
stage_scoped_secret() {
  printf '\n'
  step "Staging sandbox-scoped GitHub secret"
  run sbx secret set --sandbox "$NAME" github --ref "$TOKEN_REF" \
    || die "could not store the scoped secret; sandbox not created"
}

# Roll back on failure. The secret is staged before creation deliberately, so
# a failed create would otherwise leave a live credential scoped to a sandbox
# that does not exist, and it would silently apply to any later sandbox that
# reused the name. That is the exact hazard --destroy exists to prevent, so it
# must not be reachable by simply having creation fail.
rollback() {
  printf '\n'
  step "Creation failed, rolling back"

  # SEED is only set by a launcher that makes a seed clone. A launcher that
  # bind-mounts the user's own checkout leaves it empty and nothing here
  # removes a directory, which is the point: this path must never be able to
  # delete a real working tree.
  if [[ -n "${SEED:-}" && -d "$SEED" ]]; then
    note "removing seed clone $SEED"
    rm -rf "$SEED"
  fi

  if (( ! NO_TOKEN )); then
    remove_scoped_secret
  fi
}

# A narrow token still permits pushing anywhere in the repos it covers. The
# ruleset is the only thing keeping the agent off the default branch.
#
# jq is only needed here, so it is checked here rather than as a hard
# dependency. Without the guard a missing jq yields an empty rule list, which
# reads as "no ruleset" and fires a warning that is not true.
check_ruleset() {
  local rules protected id detail
  if ! command -v gh >/dev/null 2>&1; then
    note "ruleset   skipped, gh not installed on the host"
  elif ! command -v jq >/dev/null 2>&1; then
    note "ruleset   skipped, jq not installed on the host"
  else
    # Captured with stderr so a 403 can be told apart from a 404. Rulesets and
    # branch protection on a private repo need GitHub Team or Pro, so a private
    # repo on a free plan reports "Upgrade to GitHub Pro". Reporting that as an
    # access problem would send you looking for the wrong fix, and it is the
    # more serious case: the protection cannot be added at all, so the token's
    # push access to the default branch is unbounded.
    if rules="$(gh api "repos/$owner/$repo/rulesets" 2>&1)"; then
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
    elif printf '%s' "$rules" | grep -q "Upgrade to GitHub"; then
      printf '    WARNING  %s/%s cannot have a ruleset: rulesets on a private\n' "$owner" "$repo" >&2
      printf '             repo need GitHub Team or Pro, and this plan does not\n' >&2
      printf '             include them. Nothing will stop the agent pushing to\n' >&2
      printf '             the default branch. Either upgrade the plan, or treat\n' >&2
      printf '             this sandbox as trusted with direct push.\n' >&2
    else
      note "ruleset   could not check (no access to $owner/$repo, or repo not found)"
    fi
  fi
}

# Run from inside the sandbox deliberately, and note that this does not expose
# the credential. GH_TOKEN there is a fixed placeholder (gho_sbxprox..., byte
# for byte identical across sandboxes); the real secret stays on the host and
# the egress proxy substitutes it. So these calls exercise the token without
# anything in the sandbox, or in this script, ever holding it. A host-side
# check would have to `op read` the plaintext into a host process for no gain.
#
# These are the exact failures observed in practice. A token minted for the
# wrong resource owner still clones, because the clone above used the host's
# credentials, and `gh auth status` inside reports a healthy login either way.
# Without this, the first symptom is a call failing mid-session.
#
# Two globals shape it, both defaulting to what a launcher wants on create:
#
#   VERIFY_MODE         full       reachability plus every read permission
#                       reachable  reachability alone. What an attach wants:
#                                  revocation and rescoping both surface on the
#                                  first probe, while the permission set only
#                                  moves when the token itself is edited, so
#                                  re-running the other three every attach
#                                  spends round trips to reprint last time's
#                                  answer. --verify forces full.
#
#   UNREACHABLE_ACTION  abort      print the fix and exit. Right when the
#                                  sandbox exists only for this repo.
#                       unstage    remove the scoped secret and carry on. Right
#                                  when the sandbox holds the user's own
#                                  checkout: tearing that down over a token
#                                  problem is the more destructive answer, and
#                                  a credential staged for a repo it cannot
#                                  reach is the only part needing undone.
#
# VERIFY_GIT_DIR is the checkout HEAD is read from, so the caller decides
# whether that is a seed clone or the mounted working tree.
verify_token_access() {
  (( NO_TOKEN )) && return 0

  local head_sha degraded

  printf '\n'
  step "Verifying token access"

  # A commit SHA, not the branch name. These endpoints take {ref} as a single
  # path segment, so a default branch containing a slash (release/stable) would
  # split across segments and come back "No commit found for SHA:
  # release/stable". That 404 is indistinguishable here from a permission
  # failure, so it would warn about the exact thing it is meant to verify.
  head_sha="$(git -C "${VERIFY_GIT_DIR:-.}" rev-parse HEAD 2>/dev/null || printf 'HEAD')"

  # Exit status only; --silent discards the body. Called from `if`, so set -e
  # does not abort on the failures this exists to detect.
  token_can() { sbx exec "$NAME" -- gh api "$1" --silent >/dev/null 2>&1; }

  if token_can "repos/$owner/$repo"; then
    note "repo      $owner/$repo reachable"
  else
    printf '\n' >&2
    printf '    ERROR  the staged token cannot reach %s/%s.\n' "$owner" "$repo" >&2
    printf '           A fine-grained token has a single resource owner, so one\n' >&2
    printf '           minted for a different account or organisation will not\n' >&2
    printf '           reach this repo. Nor will one whose repository list does\n' >&2
    printf '           not include it. Nothing before this point exercised the\n' >&2
    printf '           token: cloning and the ruleset check both ran on the host\n' >&2
    printf '           with your own credentials, which is why they succeeded.\n\n' >&2
    printf '           reference  %s\n' "$TOKEN_REF" >&2
    printf '           via        %s\n\n' "$TOKEN_REF_SOURCE" >&2

    if [[ "${UNREACHABLE_ACTION:-abort}" == unstage ]]; then
      printf '           Grant the token access to %s/%s, then re-run to stage\n' "$owner" "$repo" >&2
      printf '           it again. The sandbox is left running; only the secret\n' >&2
      printf '           is being removed, since one that cannot reach the repo\n' >&2
      printf '           is no use and must not linger under this name.\n\n' >&2
      remove_scoped_secret
      return 1
    fi

    printf '           Tear down with: %s --destroy %s\n' "$PROG" "$NAME" >&2
    exit 1
  fi

  [[ "${VERIFY_MODE:-full}" == full ]] || return 0

  # Missing read permissions degrade the sandbox without breaking it, so they
  # warn rather than abort. Reading CI is the one worth taking seriously: the
  # agent cannot tell a green pipeline from an unreadable one, so it reports
  # local test runs as though they were CI.
  degraded=0
  if token_can "repos/$owner/$repo/issues?per_page=1"; then
    note "issues    readable"
  else
    note "WARNING: no Issues permission. The agent cannot read or file issues."
    degraded=1
  fi
  # Deliberately not probing check-runs. That endpoint answers
  # X-Accepted-GitHub-Permissions: checks=read, and `checks` is a GitHub App
  # permission with no fine-grained token equivalent, so it can never pass here
  # and a probe for it would report a permanent, unfixable failure. CI is read
  # through the Actions API instead; see the note below the permission list in
  # --help.
  if token_can "repos/$owner/$repo/commits/$head_sha/status"; then
    note "statuses  readable"
  else
    note "WARNING: no Commit statuses permission. Checks reported as a commit"
    note "         status are invisible to the agent."
    degraded=1
  fi
  if token_can "repos/$owner/$repo/actions/runs?per_page=1"; then
    note "actions   readable, so CI is visible via the Actions API"
  else
    note "WARNING: no Actions permission. Workflow runs and job logs are not"
    note "         readable, so the agent cannot see CI at all and any green it"
    note "         reports is a local test run, not the pipeline."
    degraded=1
  fi

  if (( degraded )); then
    note "see docs/sandbox-github-access.md for the full permission set"
  fi
}

# Picks the Claude plan name the sandbox should report, and sets
# SUBSCRIPTION_TYPE plus SUBSCRIPTION_TYPE_SOURCE when there is one. Both are
# empty when nothing usable was found, which is not an error: the sandbox works
# either way, only its banner is wrong.
#
# sbx renders the sandbox's OAuth credential file from a fixed template that has
# no subscriptionType in it, so Claude Code cannot tell which plan the session
# runs on and labels a subscription session "Claude API". The launchers pass
# what this resolves to `sbx create -e`, and the kit's startup command writes it
# into the credential file inside the container; see
# claude-config-kit/files/home/.claude-config-kit/stamp-subscription-type.sh.
#
# Precedence: SBX_CLAUDE_SUBSCRIPTION_TYPE, then the host's own account record.
# An explicit value that is malformed resolves to nothing rather than falling
# back to detection: the caller asked for something specific, and quietly
# sending a different plan name than the one they set is worse than sending
# none.
#
# The account record is ~/.claude.json, which Claude Code writes and which holds
# no tokens. Its oauthAccount.organizationType reads claude_max on a Max plan
# and claude_pro on Pro, so the claude_ prefix comes off and the rest is the
# plan name. The host keychain is deliberately not consulted: it holds the real
# OAuth credential, and reading it through `security` both prompts and, if the
# prompt is answered with Always Allow, widens that item's ACL to anything that
# can invoke `security`. That is a poor trade for a label.
#
# Read by the sourcing launcher, which shellcheck cannot see when it lints this
# file on its own.
# shellcheck disable=SC2034
resolve_subscription_type() {
  local raw origin host_config
  SUBSCRIPTION_TYPE=""
  SUBSCRIPTION_TYPE_SOURCE=""

  if [[ -n "${SBX_CLAUDE_SUBSCRIPTION_TYPE:-}" ]]; then
    raw="$SBX_CLAUDE_SUBSCRIPTION_TYPE"
    origin="SBX_CLAUDE_SUBSCRIPTION_TYPE"
  else
    host_config="$HOME/.claude.json"
    [[ -f "$host_config" ]] || return 0
    if ! command -v jq >/dev/null 2>&1; then
      note "plan      not detected, jq is not installed on the host"
      return 0
    fi
    raw="$(jq -r '.oauthAccount.organizationType // empty' "$host_config" 2>/dev/null || printf '')"
    [[ -n "$raw" ]] || return 0
    raw="${raw#claude_}"
    # A label for the preflight line, not a path to open, so the tilde is meant
    # to stay literal.
    # shellcheck disable=SC2088
    origin="~/.claude.json"
  fi

  # Plan names are lower case words (max, pro, team, enterprise). Anything else
  # is refused here rather than sent into the sandbox, where it would end up in
  # a JSON credential file.
  #
  # Filtered with `tr` under LC_ALL=C rather than a [!a-z0-9_] glob, which is
  # not the test it looks like: in a UTF-8 locale the a-z range collates
  # case-insensitively, so the glob accepts MAX and every other upper-case
  # spelling. The C locale makes the range the 26 bytes it appears to be.
  if [[ -z "$raw" || -n "$(printf '%s' "$raw" | LC_ALL=C tr -d 'a-z0-9_')" ]]; then
    note "plan      ignoring '$raw' from $origin, that is not a plan name"
    return 0
  fi

  SUBSCRIPTION_TYPE="$raw"
  SUBSCRIPTION_TYPE_SOURCE="$origin"
}
