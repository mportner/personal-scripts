# personal-scripts

Personal macOS shell scripts and configuration, kept in one repo so a new
machine is one `git clone` and one `./setup.sh` away.

Everything here targets **bash 3.2** (the version macOS ships), so it runs on a
stock system with no interpreter to install first.

## Contents

| Path | What it is |
| --- | --- |
| [`bin/brew-upgrade-safe.sh`](bin/brew-upgrade-safe.sh) | `brew upgrade` that holds casks back until a release has soaked upstream |
| [`bin/research-sandbox.sh`](bin/research-sandbox.sh) | launcher for isolated research sandboxes with open egress and a narrowly scoped GitHub token |
| [`bin/project-sandbox.sh`](bin/project-sandbox.sh) | launcher for development sandboxes on a real checkout, with the same narrowly scoped token |
| [`claude-config-kit/`](claude-config-kit/) | an [sbx](https://docs.docker.com/ai/sandboxes/) mixin kit carrying a Claude Code status line and settings into every sandbox |
| [`dev-tools-kit/`](dev-tools-kit/) | sbx mixin kit installing Node 24, pnpm, gh and the projects' supply-chain policy |
| [`research-kit/`](research-kit/) | sbx mixin kit opening full network egress for research and planning sandboxes |
| [`lib/`](lib/) | shell libraries the launchers source; never executed, never on `PATH` |
| [`test/`](test/) | the test suite and its runner, `./test/run.sh` |
| [`docs/sandbox-github-access.md`](docs/sandbox-github-access.md) | the GitHub credential model both launchers share |
| [`setup.sh`](setup.sh) | installer: symlinks `bin/` onto `PATH`, manages a block in `~/.zshrc` |
| [`uninstall.sh`](uninstall.sh) | reverses `setup.sh` |

## Install

```bash
git clone https://github.com/mportner/personal-scripts.git ~/personal-scripts
cd ~/personal-scripts
./setup.sh
```

`setup.sh` does two things:

- **`bin/`** symlinks each executable into `~/.local/bin` with a known script
  extension (`.sh`, `.bash`, `.zsh`, `.py`, `.rb`, `.pl`) stripped, so
  `brew-upgrade-safe.sh` becomes the command `brew-upgrade-safe`.
- **`~/.zshrc`** gains a marked block putting `~/.local/bin` on `PATH`, plus a
  `source` line for every fragment in `shell/`. Fragments define shell
  functions, so they must be sourced rather than executed, which is why they
  are never symlinked onto `PATH`. There are none at present, so the block is
  the `PATH` stanza alone.

It prompts before touching `~/.zshrc` and backs the file up first. If it finds
one of its marker comments without the matching partner (a half-removed block,
or a hand-edited one), it refuses to touch the file rather than guess where the
block ends. Preview without changing anything:

```bash
./setup.sh --dry-run
```

Re-running is safe and is how you pick up new scripts: it converges on the
current contents of both directories: new scripts are linked, moved ones
repointed, links to deleted scripts pruned, and the rc block rewritten if it has
drifted. Only symlinks pointing into this repo are ever touched, so it cannot
disturb entries another installer owns in `~/.local/bin`.

Set `PERSONAL_SCRIPTS_BIN` to link somewhere other than `~/.local/bin`.

### On a machine without `sbx`

Both sandbox launchers declare `# requires: sbx` in their header. `--no-sandbox`
leaves out every `bin/` script carrying that marker and installs the rest:

```bash
./setup.sh --no-sandbox
```

Because re-running converges, this doubles as the way to change your mind
later. Adding the flag on a machine that already has them prunes their links;
dropping it links them back. Neither touches anything else.

Without the flag, a missing [`sbx`](https://docs.docker.com/ai/sandboxes/) is
only a warning: the scripts are linked anyway, and named alongside the flag
that would have left them out. It can be installed afterwards, and a command
that says what it wants is easier to diagnose than a link that silently never
appeared.

The marker lives in the script rather than in a list inside `setup.sh`, so it
cannot drift when a script is added or renamed.

## Uninstall

```bash
./uninstall.sh
```

All or nothing: it removes every symlink pointing into this repo and offers to
strip the managed block from `~/.zshrc`. To remove just the sandbox launchers
and keep the rest, re-run `./setup.sh --no-sandbox` instead.

## Requirements

- macOS with [Homebrew](https://brew.sh)
- `zsh` (the macOS default): `setup.sh` manages a block in its rc file
- `jq`, required by `brew-upgrade-safe` and the status line: `brew install jq`
- [`gh`](https://cli.github.com), optional: `brew-upgrade-safe` uses it for an
  authenticated GitHub API rate limit (5000/hr rather than 60/hr), which matters
  because it makes one API call per gated package
- [`sbx`](https://docs.docker.com/ai/sandboxes/), optional: only for the kits
  and the two sandbox launchers

## Tests

```bash
./test/run.sh                                  # everything
./test/run.sh test/trim_sandbox_guidance_test.sh   # one file
```

Plain bash and `jq`, no test framework to install, so it runs on a stock macOS
and on a CI runner unchanged. `.github/workflows/checks.yml` runs it on every
push and pull request alongside shellcheck.

The suite covers the parts with logic worth pinning down: the two scripts
`claude-config-kit` runs inside a sandbox, and the plan-name resolution the
launchers share. The launchers themselves are exercised with `--dry-run`.

## The scripts

### `brew-upgrade-safe`

Upgrades formulae immediately but holds casks back until their definition has
been in the Homebrew tap for a cooldown window (default 5 days), so you are not
first to install a broken release. It builds the whole plan first, prints it in
three sections (no cooldown, past cooldown, holding back) and asks before
changing anything.

```bash
brew-upgrade-safe              # show the plan, then confirm
brew-upgrade-safe --dry-run    # plan only
brew-upgrade-safe -d 10        # 10-day cooldown
```

Security-critical packages are listed in `NEVER_GATE` inside the script and
always upgrade immediately: for a browser, a delayed security patch is a bigger
risk than a bad release. Edit that list, and `GATED_FORMULAE` next to it, to
taste.

The cooldown clock measures **packaging**, not the upstream release: it starts
at the tap commit that published the version. For a cask tracking a delayed
release channel the version can already be weeks old upstream, which is what
`NEVER_GATE` is the escape hatch for.

### `research-sandbox` and `project-sandbox`

Two launchers for `sbx` sandboxes, sharing everything about how the agent gets
at GitHub and differing in what it is allowed to touch.

```bash
research-sandbox owner/repo     # a throwaway clone, open egress
research-sandbox                # same, reading owner/repo from the cwd's origin
research-sandbox --attach       # opens an agent in it, named from the cwd's origin
research-sandbox --attach research-league-service --worktree docs

cd ~/projects/league-service
project-sandbox                 # bind-mounts this checkout; creates and exits
project-sandbox                 # a second run attaches
project-sandbox --worktree fix  # attaches with the agent on worktree-fix
```

| | `research-sandbox` | `project-sandbox` |
| --- | --- | --- |
| Workspace | a throwaway clone on a container volume | the repository root, bind-mounted |
| Network | unrestricted, via `research-kit` | the default policy |
| Getting work back | `git fetch sandbox-<name>` | it is already in your checkout |
| `--destroy` | removes the seed clone too | never removes a directory |

Both stage a **fine-grained GitHub token scoped to that sandbox alone**, so
neither inherits the global `github` secret, and both verify from inside the
sandbox afterwards that the token can actually reach the repository. That model
is written up in full in
[`docs/sandbox-github-access.md`](docs/sandbox-github-access.md): what the
token needs, why there is one per repository owner, how it reaches the sandbox
without ever being held there, and what each verification warning means.

Set one reference per owner, which both commands read:

```zsh
export SBX_GH_TOKEN_REF_MPORTNER="op://Private/gh-agent-personal/credential"
```

Both also tell the sandbox which Claude plan the session runs on, since sbx
stages the OAuth credential without one and the banner then reads
"Claude API" on a subscription session. The plan is read from the host's own
account record (`~/.claude.json`), so there is nothing to configure; set
`SBX_CLAUDE_SUBSCRIPTION_TYPE` to override it, and see
[`claude-config-kit`](claude-config-kit/README.md) for what the sandbox does
with it.

Both also carry the host's global git excludes in. sbx points
`core.excludesFile` at a file of its own inside the container, so anything you
ignore globally rather than in a committed `.gitignore` (a `.DS_Store`, a
`.claude/settings.local.json`) stops being ignored in there, and a checkout
that is clean here reads as dirty. The launchers append your patterns to the
container's file under a marked block, on create and again at every attach, so
edits to the host file are picked up and the block is rewritten rather than
stacked. Nothing happens if you have no global excludes file.

`project-sandbox` also checks what the checkout is about to hand over. It scans
for gitignored files that look like credentials (`git status` alone will not
show you those) and warns on a dirty tree, since `claude --worktree` branches
from HEAD. It asks about both on create, and on attach only when the answers
have changed.

In `project-sandbox`, `--worktree NAME` is handled by the launcher rather than
passed through to `claude`, because a worktree it does not know about is one
whose `node_modules` it cannot isolate from the host's. `research-sandbox`
forwards the flag instead: its workspace is a clone on a container volume, where
that isolation is inert and there is no host tree to pre-create in.

#### Running more than one agent in a sandbox

Every attach starts a **new** agent. Neither launcher, and neither `sbx run
--name` underneath them, returns you to an agent already running; each one adds
another to the same container. That is how you get two agents working in
parallel, and it has two consequences worth knowing.

They share a working tree unless you say otherwise, so two agents on the same
branch will overwrite each other. Give each one its own with `--worktree`, which
lands it in `.claude/worktrees/NAME` on branch `worktree-NAME`. `research-sandbox
--attach` reports how many agents are already in the sandbox and warns when a
new one would be joining them in the same tree.

An agent also **outlives the pane it was opened in**. Closing the terminal
detaches it and leaves it running inside the container, where nothing on the
host shows it exists, and there is no way to get back to it. The agent count on
attach is what surfaces them; `sbx exec <name> pgrep -x claude` lists the
process ids, and `sbx exec <name> kill <pid>` clears one out.

In a herdr pane the attach runs under argv0 `claude`, through either launcher.
Both call the same `exec`, and both decide in the shell you ran them from, which
is the shell that knows whether it is a herdr pane. What `research-sandbox`
prints at the end of a create is a pair of hand-run spellings, under a heading
saying so, because where you will attach from is not known when the sandbox is
created. herdr identifies an agent pane by its foreground process, and a sandbox
pane's is `sbx`, because the agent itself runs inside the container and is not
in the host's process tree; the session hook cannot cross that boundary either.
Without the spoof the pane reads as `agent_status: unknown` and none of `herdr
agent get`, `agent prompt --wait` or the idle/working colouring works against
it. It buys identification and state, not the Claude session id, so herdr cannot
link the pane to a transcript on disk. That would mean mounting herdr's host
socket into the sandbox, which is the boundary the sandbox exists to hold.

### `claude-config-kit`

An sbx mixin kit that installs a three-line Claude Code status line and a set of
preferred settings into every sandbox created with it. See its
[README](claude-config-kit/README.md) for the design notes and the extracted kit
spec reference.

It also repairs two things sbx does to Claude Code's own inputs. It trims the
`CLAUDE.md` sbx generates one directory **above** the workspace, which Claude
Code loads as project instructions even though no project wrote it and its
build and package-manager advice is guessed from file extensions (`npm install`
in a pnpm workspace). What sbx is actually authoritative about, the network,
git authentication and workspace mode, is kept. And it records the subscription
plan in the staged credential file, whose sbx template omits it.

> **If you are not the author:** the shipped `settings.json` enables the
> `devpowers` plugin from the `mportner/agentpowers` marketplace, which is a
> private repository and will not resolve for you. Remove the
> `enabledPlugins` and `extraKnownMarketplaces` entries from
> `claude-config-kit/files/home/.claude-config-kit/settings.json`; the status
> line and every other setting work without them.

### `dev-tools-kit`

An sbx mixin kit that installs the toolchain these projects expect, so the agent
never has to install its own. The stock image ships Node 22, no pnpm and gh
2.46, while the projects want Node 24 and a pnpm pinned per repository through
`packageManager`; sessions used to open with the agent hitting `EACCES` from
`corepack enable` and hand-rolling a pnpm shim in its scratch directory. In one
measured transcript that took 27 of 89 bash calls.

pnpm comes from its standalone release with a pinned sha256, not from corepack
or npm, and its own `manage-package-manager-versions` gives each project the
version its `packageManager` field asks for.

It also carries the host's supply-chain policy in (`minimumReleaseAge`,
`minimumReleaseAgeStrict`, `blockExoticSubdeps`) rather than leaving it to
whichever repositories happen to commit those settings, and gives the sandbox a
private `node_modules` so a Linux install stops fighting the host's macOS one
over the bind mount. See its [README](dev-tools-kit/README.md).

Adds about 30s to sandbox creation, most of it Playwright's system libraries;
`-e SBX_DEV_TOOLS_PLAYWRIGHT=0` skips those and brings it down to about 15s.

Applied by both launchers: `project-sandbox` with Playwright, `research-sandbox`
with it skipped. Research sandboxes get it mainly for the supply-chain policy:
they are the ones with unrestricted egress, so they are the last place that
should be installing packages with no release-age window.

## License

[MIT](LICENSE)
