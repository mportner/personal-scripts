# research-kit

An [sbx](https://docs.docker.com/ai/sandboxes/) **mixin kit** that opens full
network egress for sandboxes used purely for research and planning. It stacks
with `claude-config-kit` rather than replacing it.

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

Give the research token `Contents: write`, `Pull requests: write` and
`Metadata: read` on the repos you want researched, and nothing else.

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
