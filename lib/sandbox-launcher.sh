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
# resolving the Claude plan name the sandbox should report, carrying the host's
# global git excludes into the container, the --worktree flag in both its
# spellings, whether a sandbox exists, whether it is running and how many agents
# are in it, and building the attach command, including the argv0 spoof a herdr
# pane needs.
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
  local raw origin host_config cleaned
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
  #
  # Written as its own command so a `tr` that cannot run refuses the value
  # rather than accepting it: an unreachable filter returns the empty string,
  # which is what a valid plan name returns too. Same shape as the check in
  # claude-config-kit's stamp-subscription-type.sh, for the same reason.
  if ! cleaned="$(printf '%s' "$raw" | LC_ALL=C tr -d 'a-z0-9_')" \
     || [[ -z "$raw" || -n "$cleaned" ]]; then
    note "plan      ignoring '$raw' from $origin, that is not a plan name"
    return 0
  fi

  SUBSCRIPTION_TYPE="$raw"
  SUBSCRIPTION_TYPE_SOURCE="$origin"
}

# The preflight half of the plan-name fix: resolve it, say what was found, and
# build the `sbx create` arguments that carry it. Both launchers do exactly this
# and nothing else with it, so it lives here rather than as the same twelve
# lines in each. PLAN_ENV is expanded at the create call with the
# ${a[@]+"${a[@]}"} guard bash 3.2 needs for a possibly-empty array under set -u,
# so an undetected plan passes no argument at all rather than an empty one.
#
# Read by the sourcing launcher, which shellcheck cannot see when it lints this
# file on its own.
# shellcheck disable=SC2034
report_subscription_type() {
  resolve_subscription_type
  PLAN_ENV=()
  if [[ -n "$SUBSCRIPTION_TYPE" ]]; then
    note "plan      $SUBSCRIPTION_TYPE, read from $SUBSCRIPTION_TYPE_SOURCE"
    PLAN_ENV=(-e "SBX_CLAUDE_SUBSCRIPTION_TYPE=$SUBSCRIPTION_TYPE")
  else
    note "plan      not detected, so the sandbox banner will read 'Claude API'"
    note "          set SBX_CLAUDE_SUBSCRIPTION_TYPE to fix that"
  fi
}

# The first line claude-config-kit leaves on the file it trims. Duplicated from
# the script rather than shared, because the two run in different places: that
# one inside the container as POSIX sh, this one on the host. It is a wire
# format between them, so changing it means changing both.
GUIDANCE_MARKER='<!-- claude-config-kit: trimmed sbx project guidance -->'

# Says whether the kit actually trimmed the CLAUDE.md sbx generates above the
# workspace. Run from inside the sandbox after creation, for the same reason
# verify_token_access is: nothing before this point exercised it.
#
# The failure this exists to catch is silent by construction. The trim declines
# to act on a file it does not recognise, which is the right answer for a file
# another tool owns, but it means a change to sbx's template turns the fix off
# with one line in a container log nobody reads, and the invented project
# guidance comes back unannounced. That is the exact complaint the trim exists
# to answer, so it must not be able to return quietly.
check_generated_guidance() {
  local first
  # Single-quoted on purpose: WORKSPACE_DIR is the container's, and the sandbox
  # is the only place that knows where its workspace was mounted. Expanding it
  # here would read the host's environment, where it does not exist.
  # shellcheck disable=SC2016
  first="$(sbx exec "$NAME" -- sh -c \
    'head -n 1 "$(dirname "$WORKSPACE_DIR")/CLAUDE.md" 2>/dev/null' 2>/dev/null || printf '')"

  if [[ "$first" == "$GUIDANCE_MARKER" ]]; then
    note "guidance  trimmed, so only the sandbox instructions above the"
    note "          workspace are loaded, not guessed project ones"
  elif [[ -z "$first" ]]; then
    # No file above the workspace, or the read itself failed. Neither is worth a
    # warning: there is nothing there to mislead the agent.
    note "guidance  nothing generated above the workspace"
  else
    printf '    WARNING  the CLAUDE.md sbx generates above the workspace was not\n' >&2
    printf '             trimmed, so the project guidance it guesses at is loaded\n' >&2
    printf '             into every session here, alongside the instruction files\n' >&2
    printf '             the repository ships. Its first line reads:\n' >&2
    printf '               %s\n' "$first" >&2
    printf '             claude-config-kit only rewrites the file it recognises,\n' >&2
    printf '             so sbx has most likely changed its template. The trim is\n' >&2
    printf '             claude-config-kit/files/home/.claude-config-kit/\n' >&2
    printf '             trim-sandbox-guidance.sh\n' >&2
  fi
}

# --- the host's global git excludes -----------------------------------------

# The markers wrapped around the block carried below. A wire format between
# this and the container script in carry_host_excludes: the container strips
# everything between them before appending, which is what lets attach rewrite
# its block instead of stacking a second one on top.
EXCLUDES_BEGIN='# >>> personal-scripts: host global git excludes >>>'
EXCLUDES_END='# <<< personal-scripts: host global git excludes <<<'

# The global excludes file git actually reads on this host, or nothing.
#
# Asked for as a path rather than a plain string so that git expands a leading
# tilde itself. The value is written that way far more often than not, and a
# literal "~/.gitignore_global" handed to the container names a path that does
# not exist there.
#
# The XDG fallback is not a guess: git reads that file whenever
# core.excludesFile is unset, so a user who never set it can still have global
# patterns, and they would be exactly the ones this missed. A configured file
# that is absent gets no fallback, because git is not reading anything either
# and the sandbox already matches the host.
# Unqualified rather than --global: a core.excludesFile set in /etc/gitconfig
# is just as invisible in the container, and --global would resolve it to
# nothing, fall through to the XDG default and carry the wrong file, or none,
# without saying so. This asks the same question git answers for itself.
host_excludes_file() {
  local path
  # Assigned in two steps: `local path=$(...)` would take local's own status
  # and hide the failure that means the setting is unset.
  path="$(git config --get --type=path core.excludesFile 2>/dev/null)" || path=""
  [[ -n "$path" ]] || path="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
  # -f rather than -e, so a directory at the path is not mistaken for a file to
  # read, and the carry never ships a read error as if it were patterns.
  [[ -f "$path" && -r "$path" ]] || return 0
  printf '%s' "$path"
}

# The block as it will appear in the container's excludes file: the host's
# patterns between the two markers.
#
# The trailing newline is produced rather than assumed. A file whose last line
# arrives without one is ordinary, and appending the end marker straight onto
# it would both lose that pattern and leave a block whose end the container
# cannot find, so the next run would append rather than replace.
excludes_block() {
  # $1 the host file to wrap
  printf '%s\n' "$EXCLUDES_BEGIN"
  # awk rather than cat: it terminates every record with a newline, including a
  # last one that had none.
  awk '{ print }' "$1"
  printf '%s\n' "$EXCLUDES_END"
}

# The script the container runs, kept addressable rather than inlined so it can
# be tested without a container. The strip-and-append below is what makes an
# attach rewrite its own block instead of stacking a second one, and a test that
# stubs sbx would leave exactly that untested.
#
# Reads PS_EXCLUDES_BLOCK (base64), PS_EXCLUDES_BEGIN and PS_EXCLUDES_END from
# the environment. POSIX sh, because the container's /bin/sh is not bash.
#
# --global here, unlike host_excludes_file above, and the asymmetry is
# deliberate rather than a copy that drifted. That one asks what git reads on
# the host, so it must see every scope. This one picks where to WRITE, and an
# unqualified resolution could answer with a repo-local excludesFile, which in
# a bind-mounted checkout means writing the user's patterns into their own
# repository.
#
# Nothing carries .git/info/exclude, and nothing needs to: it lives inside the
# .git directory, which project-sandbox bind-mounts whole, so the container's
# git already reads the same file. A research sandbox clones instead, and git
# clone does not copy info/exclude, but that is a fresh clone with no local
# exclusions to lose.
# Single-quoted on purpose: every expansion in here belongs to the container's
# shell, not this one. PS_EXCLUDES_* arrive in its environment, and $HOME, $$
# and the command substitutions all have to be resolved there.
# shellcheck disable=SC2016
EXCLUDES_INSTALL_SH='
set -e
dest="$(git config --global --get --type=path core.excludesFile 2>/dev/null || true)"
# The XDG default rather than giving up, so this still works if sbx stops
# setting the option: that is the file git would read instead.
[ -n "$dest" ] || dest="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
mkdir -p "$(dirname "$dest")"
[ -f "$dest" ] || : > "$dest"

tmp="$dest.personal-scripts.$$"
# Removed on every path. Without it a failed decode strands the temp file beside
# the excludes file, where it is untracked clutter of the exact kind this whole
# function exists to stop.
trap "rm -f \"$tmp\"" EXIT

# Everything except a block a previous run left, then the current block. A
# plain shell loop rather than awk or sed, because the markers would have to be
# quoted through another layer to reach either, and the file is a few lines.
# The `|| [ -n "$line" ]` is what keeps a final line that has no newline.
skip=0
while IFS= read -r line || [ -n "$line" ]; do
  if [ "$line" = "$PS_EXCLUDES_BEGIN" ]; then skip=1; continue; fi
  if [ "$line" = "$PS_EXCLUDES_END" ]; then skip=0; continue; fi
  if [ "$skip" = 0 ]; then printf "%s\n" "$line"; fi
done < "$dest" > "$tmp"

printf %s "$PS_EXCLUDES_BLOCK" | base64 -d >> "$tmp"
# Same directory, so this is a rename rather than a copy: git never reads a
# half-written excludes file.
mv "$tmp" "$dest"
'

# Why a carry did not land, and what it costs. Never silent: the point of the
# whole function is that a checkout reading as dirty has an explanation, so a
# failure that says nothing would be the worst outcome available.
excludes_warning() {
  # $1 the host file, $2 what went wrong, empty if there is nothing to add
  printf '    WARNING  could not carry the host git excludes into the sandbox.\n' >&2
  printf '             Anything %s hides will read as\n' "$1" >&2
  printf '             untracked in there, which also makes the preflight\n' >&2
  printf '             report a clean checkout as dirty.\n' >&2
  if [[ -n "$2" ]]; then
    printf '               %s\n' "$2" >&2
  fi
}

# Carries the host's global excludes into the sandbox, so a checkout that is
# clean here reads as clean there.
#
# sbx points core.excludesFile at a file of its own inside the container which
# holds its own entry and nothing else, so every pattern the user ignores
# globally rather than in a committed .gitignore stops applying and the files
# it was hiding surface as untracked. That is worse than untidy: scan_findings
# keys its "dirty" finding off git status being non-empty, so a clean
# repository starts warning that uncommitted changes will not reach a
# `claude --worktree` branch, and a preflight that cries wolf stops being read.
#
# Run after create and again at attach. The second is not redundant: the host's
# file changes, and a sandbox created before this existed has no block at all.
#
# Never fails the caller. The sandbox is fine and worth keeping when only this
# does not land, and both launchers run under set -e.
carry_host_excludes() {
  local src block err
  src="$(host_excludes_file)"
  # Silent, and not a note saying there was nothing to do. Most machines
  # running this have no global excludes file at all, and this runs at every
  # attach as well as at creation, so a line here would be pure recurring noise
  # about a non-event.
  [[ -n "$src" ]] || return 0

  # Printed here rather than by the callers so it appears only when there is
  # something to report, which is what keeps the silence above silent.
  printf '\n'
  step "Carrying the host's git excludes"

  # Not routed through run(), which can neither capture the block nor express
  # the pipeline that builds it, so --dry-run is honoured here instead.
  if (( DRY_RUN )); then
    note "excludes  would carry $src"
    return 0
  fi

  # base64 rather than the text itself: a gitignore is made of the characters a
  # shell acts on, and this crosses a host shell, an argument parser and a
  # container shell to get where it is going. macOS wraps its output and GNU
  # does not, so the newlines come out either way.
  #
  # Guarded because this function promises never to fail its caller. Both
  # launchers run under `set -euo pipefail`, so a file that became unreadable
  # between host_excludes_file's test and this read would otherwise take the
  # launcher down after the sandbox had already been created.
  if ! block="$(excludes_block "$src" | base64 | tr -d '\n')"; then
    excludes_warning "$src" "could not read $src"
    return 0
  fi

  # The markers travel as environment variables so they are spelled once, here,
  # rather than once on each side of the container boundary.
  #
  # Only stderr is captured: 2>&1 >/dev/null sends it to the substitution and
  # sends stdout to the void, in that order. Discarding it instead would leave
  # the warning below unable to say why anything failed.
  if err="$(sbx exec \
              -e "PS_EXCLUDES_BLOCK=$block" \
              -e "PS_EXCLUDES_BEGIN=$EXCLUDES_BEGIN" \
              -e "PS_EXCLUDES_END=$EXCLUDES_END" \
              "$NAME" -- sh -c "$EXCLUDES_INSTALL_SH" 2>&1 >/dev/null)"; then
    note "excludes  carried $src, so what is ignored here is ignored there"
  else
    excludes_warning "$src" "$err"
  fi
  return 0
}

# --- the worktree flag ------------------------------------------------------

# WORKTREE_NAME_REASON, read below, is the sentence explaining why the calling
# launcher insists on a name. Left to the caller to set, and read with a :-
# default rather than initialised here, so it does not matter whether the
# caller sets it before or after sourcing this file.
#
# The rule is shared and the reason is not. project-sandbox cannot pre-create a
# worktree it cannot name, nor isolate the node_modules of one it did not
# pre-create; research-sandbox forwards the flag and pre-creates nothing.
# Flattening the two messages into whichever was written first would tell one
# launcher's user about machinery that launcher does not have.

# Takes the value of --worktree into WORKTREE, or dies. Deliberately stricter
# than `claude --worktree`, which will happily invent a name: naming it here is
# what lets a launcher report the branch the agent lands on and warn about the
# tree it does not share, so one it cannot name is one it can say nothing
# about.
#
# WORKTREE and WORKTREE_SEEN are read by the sourcing launcher, which is not
# something shellcheck can see when it lints this file on its own.
# shellcheck disable=SC2034
take_worktree() {
  local msg
  # -* rejected as well as empty: `--worktree --dry-run` would otherwise name a
  # worktree after the flag that followed it and swallow that flag silently.
  case "${1:-}" in
    ''|-*)
      msg="--worktree needs a name, e.g. --worktree review-fixes"
      [[ -z "${WORKTREE_NAME_REASON:-}" ]] || msg="$msg
$WORKTREE_NAME_REASON"
      die "$msg"
      ;;
  esac
  WORKTREE="$1"
  WORKTREE_SEEN=1
}

# Handles both spellings of --worktree at the front of a launcher's argument
# list. Returns 0 when $1 was one of them, having taken the name and set
# WORKTREE_SHIFT to the number of arguments the caller should consume, and 1
# when $1 is something else, leaving it to the caller's own case.
#
# A function rather than two case arms because two spellings have three call
# sites: each launcher parses its own options, and project-sandbox parses again
# after the `--`, since a worktree it is not told about is one it cannot
# isolate. Three copies of a two-line pattern is how the -* rejection came to
# be in one of them and not the others.
#
# WORKTREE_SHIFT is read by the sourcing launcher; see above.
# shellcheck disable=SC2034
take_worktree_flag() {
  case "${1:-}" in
    -w|--worktree)
      # `${2:-}` rather than need_value: a value that is missing and a value
      # that is really the next option are the same mistake, and take_worktree
      # names the flag and gives an example where need_value can only say that
      # something was wanted.
      take_worktree "${2:-}"
      WORKTREE_SHIFT=2
      ;;
    --worktree=*)
      take_worktree "${1#--worktree=}"
      WORKTREE_SHIFT=1
      ;;
    *) return 1 ;;
  esac
  return 0
}

# --- herdr ------------------------------------------------------------------

# The agent a sandbox created from here runs: every launcher in bin/ builds its
# sandbox with `sbx create claude`. It is a constant rather than an option
# because the spoof below has to name the agent that is really running, and
# this is where that assumption is depended on.
SANDBOX_AGENT=claude

# Whether the attach should run under a spoofed argv0.
#
# herdr has two ways to know a pane hosts an agent session, and a sandbox
# defeats both. The rich one is a hook: `herdr integration install claude`
# writes a Claude Code session hook that reports the session over herdr's unix
# socket, and none of that survives the container boundary, since the sandbox
# has neither herdr's environment, nor its socket, nor the hook installed. The
# fallback is the process table, and the pane's foreground process is `sbx`:
# the agent itself runs inside the container and is not in the host's process
# tree at all. So the pane reads as agent_status unknown, never appears in
# `herdr agent list`, and none of `agent get`, `agent read`, `agent prompt
# --wait` or `agent wait` works against it.
#
# Running the attach under argv0 `claude` is enough to fix that, because
# nothing else is missing: the OSC title already passes through, and herdr's
# state rules already read the sandbox's screen correctly when handed a
# snapshot of it. Only the process-table match was failing.
#
# Two things it does not buy, both fine for what the CLI needs:
#
#   session id  identification and state, not the Claude session UUID, so
#               herdr cannot link the pane to a transcript on disk. Getting
#               that means bind-mounting herdr's host socket into the
#               container, which is exactly the boundary the sandbox exists to
#               hold.
#   the shell   `exec` replaces it, so the pane closes when the session ends
#               rather than returning to a prompt. That is what a pane running
#               `claude` directly does today.
#
# Gated on HERDR_ENV so nothing changes outside a herdr pane, and on the agent
# kind because argv0 has to match the agent herdr is being told about: naming
# claude for a pane hosting something else would have herdr apply Claude Code's
# screen rules to another agent's output.
herdr_spoofs_argv0() {
  [[ "${HERDR_ENV:-}" == 1 && "$SANDBOX_AGENT" == claude ]]
}

# Whether a sandbox named $NAME exists, running or not.
#
# `sbx ls -q` prints one name per line, so an exact whole-line match is enough
# and avoids a substring hit on a longer name that contains this one.
#
# Existence and state are separate questions here. project-sandbox asks this
# one to decide whether to create or attach, and research-sandbox to reject an
# attach to a sandbox that was never there. Neither would be served by
# sandbox_running below, which answers "stopped" with a definitive no.
sandbox_exists() {
  sbx ls -q 2>/dev/null | grep -qxF -- "$NAME"
}

# Whether sandbox $NAME is running. Three outcomes, because two of them answer
# different questions:
#
#   0  running
#   1  not running, definitively: sbx answered and the status was not "running"
#   2  could not tell: jq is missing, sbx failed, or the sandbox was not listed
#
# The 1-versus-2 split is the point. A definitive "not running" means there are
# no agents in there and nothing for the caller to warn about. A status that
# could not be read means the opposite is still possible, and reporting it as
# "no agents" would silence exactly the warning the count exists to raise.
#
# Asked before the agent count below, and the only reason that count is safe to
# take: `sbx exec` starts a stopped sandbox before running anything in it, and
# a --dry-run that boots a container is not a dry run.
#
# A `sbx ls` table parse would avoid the jq dependency, but the columns are a
# display format and the JSON is the interface.
sandbox_running() {
  local status
  command -v jq >/dev/null 2>&1 || return 2
  # Deliberately not `|| printf ''` inside the substitution: swallowing the
  # failure there is what turns an unreadable status into a confident answer.
  # pipefail, which every caller happens to set, makes a failing sbx fail the
  # pipeline outright. It is not required for correctness though: without it jq
  # still succeeds on the empty input it is handed, and the empty status falls
  # to the unknown branch below. Neither way can report a sandbox it could not
  # read as stopped.
  status="$(sbx ls --json 2>/dev/null \
    | jq -r --arg n "$NAME" '.sandboxes[]? | select(.name == $n) | .status' \
      2>/dev/null)" || return 2
  case "$status" in
    running) return 0 ;;
    '')      return 2 ;;
    *)       return 1 ;;
  esac
}

# How many agent processes are alive in sandbox $NAME, as a number, or empty
# when that could not be determined. Empty is not zero: the caller has to tell
# "nobody else is here" from "could not tell", because they lead to opposite
# advice. Named a count rather than a predicate so it is not mistaken for one
# next to sandbox_running above.
#
# `sbx run` starts a new agent every time rather than returning to one already
# there, and an agent outlives the pane it was opened in: closing the terminal
# detaches it but leaves it running, with nothing on the host to show for it.
# So this count is the only way an attach can tell the caller it is about to
# put a second agent into a workspace another one is already editing.
#
# Anything that is not a number reads as none, which covers both ways this
# legitimately fails: pgrep prints 0 and exits non-zero when nothing matches,
# and sbx itself fails when the sandbox is gone. Neither is worth aborting an
# attach over, since the attach that follows reports the real error.
agent_session_count() {
  local n rc=0
  # `|| rc=$?` keeps this a condition context, so a non-zero return here does
  # not trip the caller's set -e.
  sandbox_running || rc=$?
  case "$rc" in
    0) ;;                       # running: worth asking
    1) printf '0'; return 0 ;;  # definitively stopped: no agents, and no boot
    *) return 0 ;;              # could not tell: say so by saying nothing
  esac
  # `|| true` rather than `|| n=""`: pgrep exits 1 when nothing matches, having
  # already printed a perfectly good 0, and discarding that would report a
  # known zero as unknown. The substitution assigns whatever was printed
  # regardless of the status, so the output survives and only set -e is
  # appeased.
  n="$(sbx exec "$NAME" pgrep -xc "$SANDBOX_AGENT" 2>/dev/null)" || true
  case "$n" in
    # Nothing, or not a number: sbx could not run pgrep at all, which is the
    # same "could not tell" as an unreadable status and not a zero.
    ''|*[!0-9]*) return 0 ;;
    *) printf '%s' "$n" ;;
  esac
}

# Builds ATTACH_ARGS, the list the agent is started with: the worktree the
# launcher handles itself rather than passing through, then whatever the caller
# passes here (project-sandbox's post-`--` arguments; research-sandbox has
# none).
#
# Separate from build_attach below, which turns a list of agent arguments into
# the sbx command line that carries it. This is where that list comes from, and
# it is built once per run, so the attach reported by --dry-run is the attach
# that runs.
#
# ATTACH_ARGS is read by the sourcing launcher, which shellcheck cannot see
# when it lints this file on its own.
# shellcheck disable=SC2034
build_attach_args() {
  ATTACH_ARGS=()
  if [[ -n "$WORKTREE" ]]; then
    ATTACH_ARGS=(--worktree "$WORKTREE")
  fi
  # No guard on an empty "$@": appending it adds nothing, on bash 3.2 too. The
  # ${a[@]+"${a[@]}"} idiom elsewhere in this repo is for expanding an array
  # that may be unset, which is a different thing.
  ATTACH_ARGS+=("$@")
}

# Builds the attach into ATTACH_ARGV, and sets ATTACH_ARGV0 to the name it
# should run under, empty when it runs under its own. Both the printed form and
# the exec below go through here, so the command reported is the command run:
# with the `--` handling and the gate written twice, they could drift into
# reporting one attach and running another.
#
# Anything passed is forwarded to the agent.
#
# Read by attach_command and exec_attach, which shellcheck cannot see are the
# only callers when it lints each file on its own.
# shellcheck disable=SC2034
build_attach() {
  ATTACH_ARGV=(sbx run --name "$NAME")
  if (( $# )); then
    ATTACH_ARGV+=(-- "$@")
  fi
  ATTACH_ARGV0=""
  if herdr_spoofs_argv0; then
    ATTACH_ARGV0="$SANDBOX_AGENT"
  fi
}

# The attach as a line to print: research-sandbox's closing hint and
# project-sandbox's --dry-run output.
attach_command() {
  local arg sep=""
  build_attach ${1+"$@"}
  if [[ -n "$ATTACH_ARGV0" ]]; then
    printf 'exec -a %s ' "$ATTACH_ARGV0"
  fi
  # Printed to be pasted back into a shell, so an argument that would not
  # survive that is escaped. Only where it changes something: %q on every word
  # would spell a plain command with backslashes nobody typed, and what is
  # usually being reported is a flag. The safe set is deliberately narrow, since
  # escaping something that did not need it is cosmetic and missing something is
  # a line that does not mean what it says. An empty argument is its own case,
  # matching no pattern here and otherwise vanishing from the line.
  for arg in "${ATTACH_ARGV[@]}"; do
    printf '%s' "$sep"
    sep=" "
    case "$arg" in
      '') printf "''" ;;
      *[!A-Za-z0-9._/=:-]*) printf '%q' "$arg" ;;
      *) printf '%s' "$arg" ;;
    esac
  done
}

# Replaces this process with the sbx attach, under the argv0 build_attach chose.
#
# exec rather than a child for two reasons pointing the same way: the launcher
# has nothing left to do once the session opens, and herdr matches the pane's
# foreground process, which has to be this one for the spoof to be seen at all.
exec_attach() {
  build_attach ${1+"$@"}
  if [[ -n "$ATTACH_ARGV0" ]]; then
    exec -a "$ATTACH_ARGV0" "${ATTACH_ARGV[@]}"
  fi
  exec "${ATTACH_ARGV[@]}"
}
