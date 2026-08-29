# GitHub access from a sandbox

The credential model shared by [`research-sandbox`](../bin/research-sandbox.sh)
and [`project-sandbox`](../bin/project-sandbox.sh). It is named for its subject
rather than for either command because both use it unchanged, and it covers
more than tokens: how the credential reaches the sandbox, and what stops it
being reachable from inside, are sandbox mechanics rather than GitHub facts.

Command flags live in each launcher's `--help` and in the
[README](../README.md). What is specific to research sandboxes, their clone
isolation and their open egress, is in
[`research-kit/README.md`](../research-kit/README.md).

## 1. Why a sandbox gets its own token

`sbx` stores secrets either globally or scoped to one sandbox. A global
`github` secret is inherited by every sandbox that has none of its own, and the
one most people already have there is the broad OAuth token `gh auth login`
minted, carrying `repo` and admin rights across the whole account.

That is the wrong credential to hand an agent, for two different reasons.

A research sandbox reads arbitrary web content with unrestricted egress, so it
is the single most likely place for a prompt injection to land. Whatever the
token can do is the blast radius.

A development sandbox has narrow egress but writes the real checkout, and it is
where most hours are spent. A mistake there is ordinary rather than exotic: the
wrong `gh api` call against the wrong repository, run confidently.

So both launchers stage a **fine-grained token scoped to that sandbox alone**,
and neither will fall back to the global one. `project-sandbox` warns at
preflight when a global `github` secret exists at all, because its presence
turns the narrow token into a courtesy rather than a boundary.

## 2. One resource owner per token, so two tokens

A fine-grained personal access token has exactly one **resource owner**, chosen
when the token is created and fixed thereafter. Repositories under a personal
account and repositories under an organisation therefore need two separate
tokens carrying the same permission set.

This is not a limitation worth working around. A GitHub App installed on both
accounts is the only single credential spanning owners, and its installation
tokens expire hourly, which turns staging a secret into a minting step that has
to run again every hour.

The cost is one environment variable per owner. See section 4.

## 3. The permissions, and why each write is needed

Levels are the labels GitHub's own token UI shows, so they can be selected
verbatim. Read and write always implies read.

| Permission | Level | Why |
| --- | --- | --- |
| Metadata | Read-only | mandatory, GitHub selects it for you |
| Contents | Read and write | read to clone, write to push branches and tags |
| Pull requests | Read and write | create, edit, merge, comment, `resolveReviewThread`, `requestReviews` |
| Issues | Read and write | `gh issue *`, labels, sub-issues, issue dependencies |
| Commit statuses | Read-only | `commits/{sha}/status` and `/statuses`, so checks posted as a commit status are visible |
| Actions | Read-only | `gh run view/list/watch`, job logs, and reading CI. Raise to write only if you delegate `gh workflow run` |
| Workflows | Read and write | pushing anything under `.github/workflows/` |
| Code scanning alerts | Read-only | optional, only for delegated security triage |

`Contents`, `Pull requests` and `Metadata` alone are not enough, and the gap is
silent: `gh auth status` still reports a healthy login, and the first sign of
trouble is a call failing mid-task. A real session lost `gh issue create` to it
and could not file follow-ups it had already drafted.

The PR timeline endpoint (`repos/{owner}/{repo}/issues/{n}/timeline`), which
review-loop tooling polls, is governed by Pull requests rather than Issues. It
keeps working without the Issues permission.

**Withhold Administration**, along with Secrets, Environments and Variables.
The ruleset in section 7 is the only thing keeping the agent off the default
branch, and `Administration: Read and write` would let it edit that ruleset
away. Repository administration belongs on a separate credential used from the
host, never one injected into a sandbox.

## 4. Choosing between them

One environment variable per owner, read by both launchers:

```zsh
export SBX_GH_TOKEN_REF_MPORTNER="op://Private/gh-agent-personal/credential"
export SBX_GH_TOKEN_REF_B3SOLUTIONS="op://Private/gh-agent-b3solutions/credential"
```

The owner is upper-cased with anything outside `A-Z0-9` folded to `_`, so
`mportner` becomes `SBX_GH_TOKEN_REF_MPORTNER`. Precedence, highest first:

1. `--token-ref`
2. `SBX_GH_TOKEN_REF_<OWNER>`
3. `SBX_GH_TOKEN_REF`

The owner comes from the repository, so the right token is picked without the
caller having to remember which default is currently exported:

```bash
research-sandbox b3solutions/eptools     # picks the b3solutions token
```

`research-sandbox` takes `owner/repo` or a GitHub URL, and falls back to the
origin remote of the checkout you are standing in. `project-sandbox` only ever
reads origin, since it mounts that checkout.

**Set no generic `SBX_GH_TOKEN_REF`.** It exists for completeness, and using it
defeats the point of section 2: it would quietly stage one owner's token for a
repository belonging to another, which produces a sandbox that looks healthy
and fails at the first push. Leave it unset and an owner you have not
configured yet is a preflight error naming the exact variable to set.

The variables were called `RESEARCH_GH_TOKEN_REF_*` until `project-sandbox`
arrived. The rename was a clean break with no fallback: a silent shim is how
you end up with two half-configured sets of variables and no way to tell which
one is live.

## 5. How the credential reaches the sandbox

**Staged before creation.** `sbx secret set --sandbox NAME` works for a sandbox
that does not exist yet, and both launchers rely on it. Staging first means the
sandbox never holds the global token, not even for the seconds between creation
and a later `secret set`.

Because the secret is written before the sandbox is, a failed creation would
otherwise leave a live credential scoped to a sandbox that does not exist,
which would then silently apply to any later sandbox reusing the name. That is
the exact hazard `--destroy` exists to prevent, so it must not be reachable by
creation simply failing: both launchers roll the secret back on a failed
create, and verify the removal by reading the store afterwards rather than
trusting the delete's exit status.

**The sandbox never holds the token.** `GH_TOKEN` inside a sandbox is a
placeholder, not the credential: a 40-character `gho_sbxprox...` sentinel, byte
for byte identical across sandboxes. `HTTPS_PROXY` points every request at the
sbx egress proxy, which substitutes the real secret on the host side.

Verified by comparing the value's hash in two different sandboxes (identical)
and then calling the API from each:

```
claude-personal-scripts   gh api user  ->  mportner
research-league-bot       gh api user  ->  Bad credentials (HTTP 401)
```

Same placeholder, different results, because the difference lives entirely in
what the proxy holds for each sandbox.

This is worth stating because `gh auth status` reports `using token
(GH_TOKEN)`, which reads as though the token were sitting in the environment.
It is not. An agent that could read its own credential could leak it; it
cannot, so the blast radius of a prompt injection is bounded by what the token
may do rather than by the token escaping. Which is also why the permission set
in section 3 is the entire boundary, and why it withholds Administration rather
than trusting the agent not to use it.

It is also why verification (section 8) runs the probes from **inside** the
sandbox. A host-side check would have to `op read` the plaintext into a host
process for no gain.

## 6. The `gh pr checks` ceiling

**`gh pr checks` cannot work from a fine-grained token, at any permission
level.** It resolves `statusCheckRollup`, which reaches the Checks API, and
that API answers:

```
HTTP/1.1 403 Forbidden
X-Accepted-Github-Permissions: checks=read
```

`checks` is a GitHub App permission with no fine-grained token equivalent. It
is absent from the token UI and from GitHub's permissions reference, which
carries sections for Commit statuses and Actions but none for Checks. This is a
hard ceiling, not a permission that was missed. Confirmed against a real token
holding Commit statuses read: `/status` and `/statuses` return data while
`/check-runs` and `/check-suites` return 403.

**Read CI through the Actions API instead.** `Actions: Read-only` covers it:

```bash
gh api "repos/OWNER/REPO/actions/runs?head_sha=$SHA" \
  --jq '.workflow_runs[] | "\(.name): \(.status)/\(.conclusion)"'
# Deploy: completed/success
```

This matters more than a CLI inconvenience. The session that prompted all of
this reported two PRs green on local test runs alone, because `gh pr checks`
failed and there was no known alternative. There is one, and it works. The
instruction to use it ships to the agent in `dev-tools-kit`, which is the kit
that installs `gh` and is loaded in both stacks.

## 7. Branch protection is a ruleset, not a permission

**Tokens have no branch granularity.** A fine-grained PAT is limited to an
owner, specific repositories, and permissions such as `Contents` and
`Pull requests`. Nothing restricts one to a branch, so a token that can push at
all can push to the default branch.

What actually stops that is a repository ruleset:

```json
{ "name": "main branch protection",
  "enforcement": "active",
  "conditions": { "include": ["~DEFAULT_BRANCH"] },
  "rules": ["deletion", "non_fast_forward", "pull_request"],
  "bypass": [] }
```

The `pull_request` rule forces changes to arrive via PR. `bypass: []` is doing
real work: adding yourself as a bypass actor would hand the agent that power
too, since it acts as you. Both launchers warn when the target repository has
no active ruleset requiring a PR on its default branch.

**Rulesets on a private repository need GitHub Team or Pro.** On a free plan
the API answers `Upgrade to GitHub Pro or make this repository public` with
HTTP 403, so the protection cannot be added at all and a token with
`Contents: Read and write` can push straight to the default branch. The
launchers report this separately from a missing repository, because the fix is
different and the consequence is worse: for a private repository on a free plan
the options are to upgrade, to make the repository public, or to accept that
the sandbox has direct push and treat it accordingly.

## 8. What verification tells you

Nothing before creation exercises the token. Cloning runs on the host with the
host's own credentials, and so does the ruleset check, so pointing a launcher
at an organisation repository while the personal token is exported used to
produce a sandbox that looked healthy and failed at the first push, after the
agent had done the work.

So both launchers probe the token after creating, from inside the sandbox:

```
==> Verifying token access
    repo      mportner/league-bot reachable
    issues    readable
    statuses  readable
    actions   readable, so CI is visible via the Actions API
```

| Probe | Missing means |
| --- | --- |
| `repo` | the token cannot reach this repository at all. Wrong resource owner, a repository list that omits it, or a revoked token, which fails here with `Bad credentials (HTTP 401)` rather than a permission error |
| `issues` | the agent cannot read or file issues |
| `statuses` | checks reported as a commit status are invisible to it |
| `actions` | it cannot see CI at all, so any green it reports is a local test run rather than the pipeline |

Note what is absent: there is no check-runs probe. That endpoint needs
`checks=read`, which no fine-grained token can hold (section 6), so probing it
could only ever report a permanent, unfixable failure.

**The first probe is the serious one**, and the two launchers answer it
differently because their sandboxes are worth different amounts:

- `research-sandbox` aborts. The sandbox exists only for that repository and a
  seed clone is cheap to recreate.
- `project-sandbox` leaves the sandbox running, removes the scoped secret, and
  prints the fix. Its sandbox holds the user's own checkout, so tearing it down
  over a token problem would be the more destructive answer. A credential
  staged for a repository it cannot reach is the only part that needs undoing;
  widen the token and re-run, and the secret is staged again.

The other three warn and continue, because the sandbox is still usable without
them.

**Full set on create, reachability alone on attach.** Revocation and rescoping
both surface on the first probe, while the permission set only moves when the
token itself is edited, so re-running the other three at every attach spends
round trips reprinting the previous answer. `project-sandbox --verify` forces
the full set.
