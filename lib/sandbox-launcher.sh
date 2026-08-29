#
# File:    sandbox-launcher.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# Sandbox and GitHub machinery shared by every sbx launcher in bin/: repo
# argument parsing, owner-scoped token reference resolution, the op
# preflight, sandbox-scoped secret staging, its rollback, the ruleset check,
# and post-create token verification.
#
# These functions operate on globals their caller sets (REPO_ARG, NAME,
# SEED, TOKEN_REF, TOKEN_REF_EXPLICIT, TOKEN_REF_SOURCE, NO_TOKEN, DRY_RUN,
# ...) rather than taking parameters, matching the flat, global-variable style
# the rest of this repo already uses for these scripts. They also call the
# caller's own run(), so staging still honours --dry-run.
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

# A fine-grained token has exactly one resource owner, so a personal account
# and an organisation need separate tokens. Sets owner_key, and TOKEN_REF plus
# TOKEN_REF_SOURCE when one is found.
#
# Precedence: --token-ref (TOKEN_REF_EXPLICIT, set by the caller's option
# parsing), then RESEARCH_GH_TOKEN_REF_<OWNER>, then RESEARCH_GH_TOKEN_REF. The
# owner is upper-cased with anything outside A-Z0-9 folded to _, so mportner
# becomes RESEARCH_GH_TOKEN_REF_MPORTNER.
resolve_token_ref() {
  local owner_var
  owner_key="$(printf '%s' "$owner" | LC_ALL=C tr '[:lower:]' '[:upper:]' \
    | LC_ALL=C tr -c 'A-Z0-9' '_')"
  if (( TOKEN_REF_EXPLICIT )); then
    TOKEN_REF_SOURCE="--token-ref"
  else
    owner_var="RESEARCH_GH_TOKEN_REF_$owner_key"
    if [[ -n "${!owner_var:-}" ]]; then
      TOKEN_REF="${!owner_var}"
      TOKEN_REF_SOURCE="$owner_var"
    elif [[ -n "${RESEARCH_GH_TOKEN_REF:-}" ]]; then
      TOKEN_REF="$RESEARCH_GH_TOKEN_REF"
      TOKEN_REF_SOURCE="RESEARCH_GH_TOKEN_REF"
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
secret_present() {
  sbx secret ls 2>/dev/null | awk -v n="$NAME" 'NR > 1 && $1 == n { found = 1 } END { exit !found }'
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
# wrong resource owner still clones, because the seed clone above used the
# host's credentials, and `gh auth status` inside reports a healthy login
# either way. Without this, the first symptom is a call failing mid-session.
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
  head_sha="$(git -C "$SEED" rev-parse HEAD 2>/dev/null || printf 'HEAD')"

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
    printf '           reach this repo. The seed clone used your host\n' >&2
    printf '           credentials, which is why it still succeeded.\n\n' >&2
    printf '           reference  %s\n' "$TOKEN_REF" >&2
    printf '           via        %s\n\n' "$TOKEN_REF_SOURCE" >&2
    printf '           Tear down with: research-sandbox --destroy %s\n' "$NAME" >&2
    exit 1
  fi

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
    note "see research-kit/README.md for the full permission set"
  fi
}
