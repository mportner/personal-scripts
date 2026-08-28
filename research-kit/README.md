# research-kit

An [sbx](https://docs.docker.com/ai/sandboxes/) **mixin kit** that opens full
network egress for sandboxes used purely for research and planning. It stacks
with `claude-config-kit` and `dev-tools-kit` rather than replacing them.

Not meant to be applied by hand. `bin/research-sandbox.sh` combines it with the
other two mechanisms that make it safe:

```bash
research-sandbox --token-ref op://Private/gh-research/credential owner/repo
research-sandbox --destroy research-<repo>
```

## The three mechanisms

No single sbx feature delivers "open internet, fresh clone, no local
filesystem". Three do, and they are independent:

| Concern | Mechanism | Where it lives |
| --- | --- | --- |
| Open network | `permissions.network.allow: ["**"]` | this kit |
| No host filesystem | `--clone` | launcher flag |
| Which repos GitHub-wise | fine-grained PAT, sandbox-scoped | `sbx secret set --sandbox` |
| Which branches | repository ruleset | GitHub, not sbx |
| Package install policy | `minimumReleaseAge` and friends | [`dev-tools-kit`](../dev-tools-kit/) |

### Why the toolchain kit rides along

`bin/research-sandbox.sh` also passes [`dev-tools-kit`](../dev-tools-kit/), for
two reasons.

Research leans on pnpm: `pnpm view` and `pnpm why` are how you answer a question
about a dependency, and the base image has no pnpm at all.

The second reason matters more. `dev-tools-kit` is what carries
`minimumReleaseAge`, `minimumReleaseAgeStrict` and `blockExoticSubdeps` into a
sandbox. Without it, the one sandbox with unrestricted egress reading untrusted
web content would also be the only one installing packages with no release-age
window, which is precisely backwards.

The launcher passes `-e SBX_DEV_TOOLS_PLAYWRIGHT=0`, halving creation time
(roughly 30s to 15s) by skipping browser system libraries that research work
does not use. That kit's `node_modules` isolation is inert here: it only acts on
bind-mounted (virtiofs) paths, and a `--clone` workspace is already on a
container volume.

### Network

A kit's network rules become a policy **scoped to the sandbox created with the
kit**, layered on top of the global preset:

```
POLICY      SOURCE  APPLIES TO              SUMMARY
8b3e41ac…   kit     sandbox:research-test   network: 7 allow
```

Verified that this does not leak: with a research sandbox running,
`sbx policy check network arxiv.org` still reported `Denied` globally and for
`claude-personal-scripts`, while the research sandbox reached
`en.wikipedia.org` and `arxiv.org` with HTTP 200.

The alternative, `sbx policy init allow-all`, is global and one-time; changing
it afterwards requires `sbx policy reset`, which wipes every policy, secret and
piece of state. Hence the kit.

### Filesystem

`--clone` is a genuinely different model from the default bind mount, not a
variation on it:

| | Default (bind) | `--clone` |
| --- | --- | --- |
| Workspace | the host directory itself | container volume, a real clone |
| Agent writes | land on your real files | stay in the container |
| Host edits mid-session | visible immediately | not visible in the working tree |
| Host repo readable | yes, read-write | read-only, at `/run/sandbox/source` |
| Getting work back | already there | `git fetch sandbox-<name>` |

Confirmed by editing a file on the host after creation: the sandbox working
tree still showed the old content (`/dev/vdj ext4`, a volume) while
`/run/sandbox/source` showed the new. Writes to `/run/sandbox/source` fail with
`Read-only file system`.

That read-only window is the one caveat: `--clone` is not zero host exposure.
The launcher keeps it harmless by seeding from a throwaway clone under
`~/.local/state/sbx-research/<name>/` rather than any real working tree.

### GitHub

**Tokens have no branch granularity.** Fine-grained PATs are limited to an
owner, specific repositories, and permissions such as `Contents` and
`Pull requests`. Nothing restricts a token to a branch, so a token that can
push at all can push to the default branch.

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
too, since it acts as you. The launcher warns when a target repo has no active
ruleset requiring a PR on its default branch.

**Rulesets on a private repository need GitHub Team or Pro.** On a free plan
the API answers `Upgrade to GitHub Pro or make this repository public` with
HTTP 403, so the protection cannot be added at all and a token with
`Contents: write` can push straight to the default branch. The launcher reports
this separately from a missing repo, because the fix is different and the
consequence is worse. For a private repo on a free plan the options are to
upgrade, to make the repo public, or to accept that the sandbox has direct push
and treat it accordingly.

### Which permissions the token needs

Derived from what the agent actually runs, counted across real sessions:
`gh pr checks` leads at 106 invocations, then `gh pr view` (79), `gh issue
view` (56), `resolveReviewThread` (48), `gh issue create` and `gh pr create`
(25 each). Levels use the labels GitHub's token UI shows, so they can be
selected verbatim; Read and write always implies read.

Merging is listed once, under Pull requests. Contents needs write regardless,
because the agent pushes branches.

**`gh pr checks` cannot work from a fine-grained token, at any permission
level.** It resolves `statusCheckRollup`, which reaches the Checks API, and
that API answers:

```
HTTP/1.1 403 Forbidden
X-Accepted-Github-Permissions: checks=read
```

`checks` is a GitHub App permission with no fine-grained token equivalent. It
is absent from the token UI and from GitHub's permissions reference, which
carries sections for Commit statuses and Actions but none for Checks. So this
is a hard ceiling, not a permission that was missed.

Confirmed against a real token holding Commit statuses read: `/status` and
`/statuses` return data while `/check-runs` and `/check-suites` return 403.

**Read CI through the Actions API instead.** `Actions: Read-only` covers it:

```bash
gh api "repos/OWNER/REPO/actions/runs?head_sha=$SHA" \
  --jq '.workflow_runs[] | "\(.name): \(.status)/\(.conclusion)"'
# Deploy: completed/success
```

This matters more than a CLI inconvenience. The original session reported two
PRs green on local test runs alone, because `gh pr checks` failed and there was
no known alternative. There is one, and it works.

| Permission | Level | Covers |
| --- | --- | --- |
| Metadata | Read-only | mandatory, selected for you |
| Contents | Read and write | read to clone, write to push branches and tags |
| Pull requests | Read and write | create, edit, merge, comment, `resolveReviewThread`, `requestReviews` |
| Issues | Read and write | `gh issue *`, labels, sub-issues, issue dependencies |
| Commit statuses | Read-only | `gh pr checks`, `statusCheckRollup` |
| Actions | Read-only | `gh run view/list/watch`, job logs. Raise to write only if you delegate `gh workflow run` |
| Workflows | Read and write | pushing anything under `.github/workflows/` |
| Code scanning alerts | Read-only | optional, only for delegated security triage |

An earlier version of this file recommended `Contents`, `Pull requests` and
`Metadata` alone. That is not enough, and the gap is silent: `gh auth status`
still reports a healthy login, and the first sign of trouble is a call failing
mid-task. A real session lost both `gh issue create` and `gh pr checks` to it
and merged two PRs having only ever seen local test results.

Note that the PR timeline endpoint (`repos/{o}/{r}/issues/{n}/timeline`), which
review-loop tooling polls, is governed by Pull requests rather than Issues. It
keeps working without the Issues permission.

**Withhold Administration**, along with Secrets, Environments and Variables.
The `bypass: []` ruleset above is the only thing stopping a push to the default
branch, and `Administration: write` would let the agent edit that ruleset away.
Repository administration belongs on a separate credential used from the host,
never one injected into a sandbox.

### One token per owner

A fine-grained token has exactly one resource owner, chosen at creation and
fixed thereafter. Repos under a personal account and repos under an
organisation therefore need two tokens carrying the same permission set, each
referenced by its own `--token-ref`. This costs nothing in practice, since
`sbx secret set --sandbox NAME` is already per-sandbox.

A GitHub App installed on both accounts is the only single credential spanning
owners, but its installation tokens expire hourly, which turns staging the
secret into a minting step rather than a one-off.

The launcher picks between them from the repo argument, so the caller does not
have to remember which default is currently exported:

```bash
export RESEARCH_GH_TOKEN_REF_MPORTNER=op://Private/gh-agent-personal/credential
export RESEARCH_GH_TOKEN_REF_B3SOLUTIONS=op://Private/gh-agent-b3solutions/credential

research-sandbox b3solutions/eptools     # picks the b3solutions token
```

The owner is upper-cased with anything outside `A-Z0-9` folded to `_`.
`--token-ref` still wins over both variables, and plain
`RESEARCH_GH_TOKEN_REF` remains the fallback when no owner-specific one is set.

### Why the wrong token used to go unnoticed

Nothing before creation exercises the token. The seed clone runs on the host
with the host's own credentials, and so does the ruleset check, so pointing the
launcher at an organisation repo while the personal token is exported produced
a sandbox that looked healthy and failed at the first push, after the agent had
done the work.

So the launcher verifies after creating, from inside the sandbox:

```
==> Verifying token access
    repo      mportner/league-bot reachable
    issues    readable
    checks    readable
    actions   readable
```

An unreachable repo aborts with the reference that was used and how it was
chosen, since nothing will work. Missing read permissions warn and continue,
because the sandbox is still usable without them.

The checks run inside the sandbox rather than on the host on purpose, and
running them there does not expose the credential. See below.

A revoked or expired token fails the first check too, with
`Bad credentials (HTTP 401)` rather than a permission error. That is the same
abort path, which is intended: neither is worth starting a session on.

### The sandbox never holds the token

`GH_TOKEN` inside a sandbox is a placeholder, not the credential. It is a
40-character `gho_sbxprox...` sentinel, byte for byte identical across
sandboxes, and `HTTPS_PROXY` points every request at the sbx egress proxy,
which substitutes the real secret on the host side.

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
It is not, and the distinction matters here more than anywhere else: this is
the one sandbox with unrestricted egress reading untrusted web content. An
agent that could read its own credential could leak it. It cannot, so the
blast radius of a prompt injection is bounded by what the token may do, not by
the token escaping.

It also means the permission set is the entire boundary, which is why the table
above withholds Administration rather than trusting the agent not to use it.

## Why the secret is staged before creation

`sbx secret set --sandbox NAME` works for a sandbox that does not exist yet.
The launcher relies on this: staging the narrow token first means the sandbox
never holds the global one, not even for the seconds between creation and a
later `secret set`. The global token carries `repo` and `admin=true`, which is
precisely what should not be present in a sandbox reading untrusted web pages.

`--destroy` removes the scoped secret along with the sandbox, so a later
sandbox reusing the name does not silently inherit it.

## Agent instructions

The kit ships an `agentInstructions.content` block telling the agent there is
no host filesystem, that web content is untrusted data rather than
instructions, and that the default branch is protected by design so a refused
push is expected.

For a mixin this is written to `kits-agent-context/<kit-name>.md` and
referenced from a `## Kits` section in `CLAUDE.md`, which the agent reads on
demand. Verified in a live sandbox: `CLAUDE.md` lands one level above the
workspace, which is still an ancestor of the agent's cwd, so it is picked up.
Both files are container-only; the host seed directory stays clean.

Note this is a **v2 spelling difference**: v1 used a top-level `agentContext:`,
which v2 rejects with `field agentContext not found in type spec.specFileV2`.
The v2 form is nested:

```yaml
agentInstructions:
  content: |
    ...
```

## Verified behaviour

Tested end to end against sbx 0.39.0:

- `sbx kit validate` passes; `inspect` reports `Network: 1 allow, 0 deny`.
- A real sandbox reached `en.wikipedia.org` and `arxiv.org` (HTTP 200) while
  the global policy and the main sandbox still denied them.
- Workspace is a container volume; `/Users/mike/personal-scripts` is not
  visible from inside.
- `claude-config-kit` still applies alongside: `statusline.sh` present.
- The `## Kits` pointer resolves to the kit's context file.
- `--destroy` removes sandbox, seed clone, scoped secret and policy rules.

Launcher argument handling was tested separately: `owner/repo`, full HTTPS URL,
`.git` suffix and SSH form all normalise identically; `a/b/c` and a bare word
are rejected; `cli/cli` (owner equal to repo name) is accepted; the ruleset
check correctly distinguishes a protected repo from an unprotected one; and
creating without a token reference aborts rather than falling back to the
global token.

See `../claude-config-kit/README.md` for the general kit spec reference.
