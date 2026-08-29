# research-kit

An [sbx](https://docs.docker.com/ai/sandboxes/) **mixin kit** that opens full
network egress for sandboxes used purely for research and planning. It stacks
with `claude-config-kit` and `dev-tools-kit` rather than replacing them.

This file covers what is specific to research sandboxes: the open egress, the
clone isolation, and why neither is safe without the other. Everything about
the GitHub credential (which permissions, why one token per owner, how it
reaches the sandbox, the `gh pr checks` ceiling, branch protection, and what
verification reports) is shared with `project-sandbox` and lives in
[`docs/sandbox-github-access.md`](../docs/sandbox-github-access.md).

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
| Which repos GitHub-wise | fine-grained PAT, sandbox-scoped | [`docs/sandbox-github-access.md`](../docs/sandbox-github-access.md) |
| Which branches | repository ruleset | [`docs/sandbox-github-access.md`](../docs/sandbox-github-access.md) |
| Package install policy | `minimumReleaseAge` and friends | [`dev-tools-kit`](../dev-tools-kit/) |

## Network

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

## Filesystem

`--clone` is a genuinely different model from the default bind mount, not a
variation on it:

| | Default (bind) | `--clone` |
| --- | --- | --- |
| Workspace | the host directory itself | container volume, a real clone |
| Agent writes | land on your real files | stay in the container |
| Host edits mid-session | visible immediately | not visible in the working tree |
| Host repo readable | yes, read-write | read-only, at `/run/sandbox/source` |
| Getting work back | already there | fetch from the seed clone, below |

Confirmed by editing a file on the host after creation: the sandbox working
tree still showed the old content (`/dev/vdj ext4`, a volume) while
`/run/sandbox/source` showed the new. Writes to `/run/sandbox/source` fail with
`Read-only file system`.

### The seed clone

That read-only window is the one caveat: `--clone` is not zero host exposure,
because sbx clones the workspace *from* a host directory and leaves that
directory mounted read-only for the session.

The launcher keeps that harmless by never pointing it at a real working tree.
It clones the repo fresh from GitHub into
`~/.local/state/sbx-research/<name>/`, hands sbx that throwaway as the source,
and so the only host path exposed is one containing nothing the agent could not
already fetch itself. Override the parent directory with `RESEARCH_SEED_ROOT`.

The seed lives as long as the sandbox does, because it is also how work comes
back out. `--destroy` removes it along with the sandbox and the scoped secret,
and a failed creation rolls it back the same way, so a half-made sandbox does
not strand a clone.

### Getting work back

The sandbox's workspace is a container volume, so nothing the agent commits
lands in your checkout. sbx registers a `sandbox-<name>` remote in the seed
clone pointing at the sandbox's copy, and the launcher prints the line that
uses it:

```bash
git -C ~/.local/state/sbx-research/<name> fetch sandbox-<name>
git -C ~/.local/state/sbx-research/<name> log sandbox-<name>/main
```

So the seed is not scratch space that can be tidied up early; it is the only
route back out. That is also why `--destroy` is the way to remove it rather
than deleting the directory by hand.

## Why the two are only sound together

`permissions.network.allow: ["**"]` and `--clone` are listed as independent
mechanisms above, and they are, but neither would be acceptable on its own.

Unrestricted egress means the sandbox reads arbitrary web pages, which makes it
the single most likely place for a prompt injection to land. Clone isolation is
what bounds the consequence: the agent's writes go to a container volume, the
one host path in reach is read-only and contains only a throwaway clone, and
the credential it holds is a placeholder the proxy substitutes rather than a
token it could exfiltrate.

Take either away and the pairing stops working. That is why
`bin/project-sandbox.sh` does **not** load this kit: it bind-mounts a real
checkout, so the agent can write files you care about, and it stays on the
default egress policy instead.

## Why the toolchain kit rides along

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

## Agent instructions

The kit ships an `agentInstructions.content` block telling the agent there is
no host filesystem and that web content is untrusted data rather than
instructions.

What the agent is told about *using* GitHub, that the default branch is
protected by design so a refused push is expected, and that CI is read through
the Actions API rather than `gh pr checks`, lives in
[`dev-tools-kit`](../dev-tools-kit/). That kit installs `gh` and is loaded in
both the research and the development stacks, while this one is loaded in only
the first; a development sandbox needs those instructions just as much.

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
