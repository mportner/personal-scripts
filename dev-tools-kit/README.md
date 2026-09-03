# dev-tools-kit

An [sbx](https://docs.docker.com/ai/sandboxes/) **mixin kit** that puts the
toolchain these projects expect into a sandbox before the agent starts, so the
agent never has to install its own.

```bash
sbx create claude \
  --kit ~/personal-scripts/claude-config-kit \
  --kit ~/personal-scripts/dev-tools-kit .
```

`bin/project-sandbox.sh` and `bin/research-sandbox.sh` both pass this kit
alongside `claude-config-kit`, so a sandbox from either launcher already has
the pair.

## Why

The stock `docker/sandbox-templates:claude-code-docker` image ships Node 22 from
Ubuntu universe, no pnpm at all, and gh 2.46. Both league projects declare
`engines.node` 24 and pin pnpm through `packageManager`, so every session used
to open with the agent rediscovering that. From a real sandbox transcript:

```
pnpm: command not found
corepack enable          → EACCES: symlink '/usr/bin/pnpm'
corepack pnpm --version  → EACCES: mkdir (COREPACK_HOME does not exist)
→ set COREPACK_HOME to the scratch dir, hand-write a pnpm shim into scratch/bin
[WARN] Unsupported engine: wanted {"node":"^24.0.0"} (current: v22.22.1)
→ npm install node@24 into a scratch dir to get node-linux-arm64
```

27 of 89 bash calls in that session went to toolchain wrangling, over about
twelve minutes, before any work started. A second session spent 8 of 18.

## What it installs

| | Version | Source | Verified by |
| --- | --- | --- | --- |
| mise | 2026.9.1 | github.com release | `SHASUMS256.txt` |
| Node | 24.20.0 | mise `core:node` → nodejs.org | `SHASUMS256.txt` |
| npm | bundled with Node | (as above) | (as above) |
| pnpm | 11.24.0 baseline, per project thereafter | mise `aqua:pnpm/pnpm` → github.com release | aqua registry |
| gh | 2.98.0 | github.com release | `gh_*_checksums.txt` |
| trufflehog | 3.97.1 | github.com release | `trufflehog_*_checksums.txt` |
| shellcheck, xz-utils, wget, file, tree, unzip | distro | apt | apt signatures |
| Playwright chromium system libs | distro | apt | apt signatures |

mise installs into one shared directory, `/usr/local/share/mise`, with
`MISE_DATA_DIR` pointing at it so the agent's shims find it. `node`, `npm`,
`npx`, `pnpm` and `pnpx` are symlinked from there into `/usr/local/bin`, which
precedes `/usr/bin` on PATH, so the distro's Node 22 is shadowed rather than
removed and nothing in the base image is disturbed. Symlinks rather than
putting the shim directory on PATH, which a kit cannot do without rewriting
PATH wholesale.

`docker` and `docker compose` are already in the base image (29.7.1 / v5.4.0)
and need nothing from this kit.

## pnpm: mise, not corepack and not npm

The two projects pin different pnpm versions, league-bot `pnpm@11.17.0` and
league-service `pnpm@11.7.0`, so a single global pnpm would be wrong for at
least one of them. Corepack is the usual answer and is the wrong one here: it
is deprecated upstream and on its way out of the Node distribution, and the
base image's copy (0.24.0) is too old to fetch a modern pnpm.

The obvious alternative is to install one pnpm and let pnpm's own
`manage-package-manager-versions` do the rest, since it reads `packageManager`
and switches itself to that exact version. That is what this kit used to do,
and it is what broke.

### What went wrong

pnpm does not "switch itself" in place. It fetches a **second** pnpm from the
npm registry as `@pnpm/exe` and re-executes it, into the project's store. That
package ships a 34 byte placeholder where its binary should be:

```
$ node -e 'console.log(require("@pnpm/exe/package.json").scripts.preinstall)'
node setup.js
```

`setup.js` resolves the platform package (`@pnpm/linux-arm64` here) and
hardlinks its 146 MB binary over the placeholder. When that step does not
complete, the placeholder is what runs, and every pnpm invocation in the
project dies with `sh` reporting its first line of prose:

```
pnpm: 1: This: not found
```

That binary is also one this kit never pinned or verified, which made the claim
that nothing goes through npm untrue in practice.

There is no way to turn the behaviour off. pnpm 11 removed the setting, so
`manage-package-manager-versions` in `.npmrc`, on the command line, as an
environment variable, and in `/usr/local/lib/pnpm/dist/pnpmrc` are all inert.

### What mise changes

Self-management does not trigger when the running pnpm **already is** the
pinned version. Verified with pnpm 11.24.0 in a project pinning
`pnpm@11.24.0`:

```
$ pnpm install --store-dir ./store
Done in 495ms using pnpm v11.24.0
$ find ./store -maxdepth 6 -path '*@pnpm/exe*'
   (empty)
```

The same test pinning 11.17.0 does download it. So this is not a workaround for
the placeholder: the package is never fetched.

mise is told to read the same field:

```toml
# files/home/.config/mise/config.toml
[tools]
node = "24.20.0"
pnpm = "11.24.0"

[settings]
idiomatic_version_file_enable_tools = ["pnpm"]
```

and resolves each project's pin from its own `package.json`:

```
$ cd league-service && mise current pnpm
11.7.0
```

so the shim on PATH is that version and pnpm has nothing to reach for. The
baseline in `[tools]` covers everything outside a project.

mise verifies what it installs. Observed at sandbox creation:

```
mise node@24.20.0    [2/3] checksum node-v24.20.0-linux-arm64.tar.gz
mise pnpm@11.24.0    [2/3] verify GitHub artifact attestations
mise pnpm@11.24.0    [2/3] ✓ GitHub artifact attestations verified
mise pnpm@11.24.0    [2/3] checksum pnpm-linux-arm64.tar.gz
```

`core:node` checks nodejs.org's `SHASUMS256.txt`; `aqua:pnpm/pnpm` resolves to
pnpm's own GitHub release rather than the npm registry and checks both its
build provenance attestation and its checksum, which is stronger than the
hand-pinned sha256 it replaces. mise itself is pinned by version in `spec.yaml`
and checked against the `SHASUMS256.txt` published with its release.

`mise` is also an [official kit](https://github.com/docker/sbx-kits-contrib/tree/main/mise)
in `docker/sbx-kits-contrib`. This kit installs the binary itself rather than
stacking that one, because it needs the tools installed at creation time and
the contrib kit deliberately ships no toolchain.

### No trust configuration

mise refuses to evaluate an untrusted config, and does so silently, which would
be a problem worth handling. It is not one here: the trust gate covers the
parts of a config that execute, `[env]` and `[tasks]`, not tool versions. An
untrusted `mise.toml` and an untrusted `package.json` both still resolve their
pin. Nothing in this kit reads project `[env]`, because the two `PNPM_CONFIG_`
settings below cover every project at once.

`PNPM_HOME` is `/home/agent/.local`, not the more obvious
`/home/agent/.local/share/pnpm`, because pnpm derives its global bin directory
as `$PNPM_HOME/bin` and `~/.local/bin` is already first on PATH. With the
default, every `pnpm config`, `pnpm bin -g` and global install exits 1 with
*"the configured global bin directory is not in PATH"*.

## Supply-chain policy

The sandbox otherwise had none. The host's global pnpm config and `~/.npmrc`
ship as static files so the same rules apply here:

```yaml
# files/home/.config/pnpm/config.yaml   (host parity)
blockExoticSubdeps: true
minimumReleaseAge: 7200        # 5 days
minimumReleaseAgeStrict: true
```

Without them a sandbox is hardened only inside repositories that commit these
settings to `pnpm-workspace.yaml`. Everything else, a scratch install, a
`pnpm dlx`, a repository that has not adopted the policy yet, runs on pnpm's
permissive defaults.

Nothing this kit installs goes through npm, npx or corepack, which became true
rather than aspirational when `packageManager` stopped pulling a second pnpm
off the registry. The tools it downloads (mise, `gh`, trufflehog, and Node and
pnpm through mise) are pinned to exact versions and checked against the
publisher's own checksum manifest. Everything else is an apt package: signed
by the distro and versioned by it, so those track the Ubuntu repository rather
than a pin here. That constraint is why the
Playwright system libraries are apt-installed from Playwright's own list rather
than by running `playwright install-deps`: reaching that command means fetching
the playwright package first, at creation time, with no way to apply the
release-age window to it.

Note that npm counts `min-release-age` in **days** and pnpm counts
`minimumReleaseAge` in **minutes**, so the `5` in `.npmrc` and the `7200` in
`config.yaml` are the same five-day window rather than a disagreement.

The pnpm baseline in `config.toml` is the one pin needing a manual check on
bump, because mise's install is not subject to the release-age window that
governs everything a project installs.

## Keeping pnpm off the workspace mount

The workspace is bind-mounted from the host, so a sandbox used to see the
host's macOS `node_modules`:

```
@esbuild+darwin-arm64@0.28.1      @turbo+darwin-arm64@2.10.8
lightningcss-darwin-arm64@1.32.0  lefthook-darwin-arm64@2.1.10
```

Linux cannot run those, so every install re-resolved the whole tree over
virtiofs and wrote the result back onto the host, corrupting it in both
directions. That is where the `ERR_MODULE_NOT_FOUND`, `prebuild-install` and
symlink churn in the old transcripts came from.

The kit declares a sized volume and points pnpm at it:

```yaml
volumes:
  - path: /var/lib/pnpm
    size: 10g
```

```
PNPM_CONFIG_STORE_DIR=/var/lib/pnpm/store
PNPM_CONFIG_VIRTUAL_STORE_TYPE=global
```

Both settings are needed. The store on its own is not enough: left at its
default the virtual store stays at `<project>/node_modules/.pnpm`, on the
workspace mount, and pnpm cannot hardlink from a store on a different
filesystem, so it copies every package instead. `virtualStoreType: global`
(pnpm 11.23+) puts the virtual store inside the store, so the two are on one
filesystem by construction and packages are symlinked straight out of it.

What is left in the workspace is the symlink farm and pnpm's own metadata.
Measured on a one-dependency project:

```
in-tree node_modules:   9 entries
store:                291 files
```

Note the prefix. pnpm 11 reads `pnpm_config_*` and `PNPM_CONFIG_*`; the older
`npm_config_*` spelling is ignored for these settings and says nothing about
it. Verified against pnpm 11.24.0, where `npm_config_store_dir` left
`pnpm store path` at its default.

### What this replaced

A startup command used to walk `$WORKSPACE_DIR` and bind-mount a private
directory over every `node_modules` it found or expected, with a second copy of
the same logic in `project-sandbox` for worktrees. It is gone, and so is the
`isolate_worktree_node_modules` function.

It had three problems, all of which the volume avoids rather than fixes:

- **It needed root and `mount --bind`,** and every failure was swallowed. The
  startup command must exit 0 or it takes the other kits down with it, so the
  mounts end `2>/dev/null || true`. A sandbox with no isolation at all looked
  exactly like a working one.
- **It could not cover a worktree created mid-session.** A startup command sees
  the workspace as it stood at container start, which is why the launcher
  needed its own copy, and why a worktree `claude` created for itself got
  nothing.
- **The backing directory was on the container overlay,** because a comment
  here recorded that `volumes[].path` takes no size and sbx gives one 488M.
  That is no longer true: spec v2 defines `size`, and sbx 0.39.0 gives a kit
  asking for `10g` a 9.8G ext4 filesystem.

Volumes survive stop/start and are dropped by `sbx rm`, which is the same
lifecycle the overlay directory had.

Clone-mode sandboxes need nothing special. There is no workspace mount to keep
pnpm off, and pointing the store at a volume is right either way.

### What this changes for you

The host `node_modules` is invisible inside the sandbox, so a fresh
`pnpm install` is needed once per sandbox. Measured on a cold sandbox:

| | league-service (1109 pkgs, 7 workspaces) | league-bot |
| --- | --- | --- |
| `pnpm install` | 4.7s | 3.8s |
| `pnpm typecheck` | 2.2s, 5/5 tasks | passes |
| `pnpm test` | | 194/194 passing |

A project pinning a pnpm older than 11.23 through `packageManager` does not get
`virtualStoreType`, so its virtual store stays in the tree. Bumping the pin is
the fix.

## Cost

About 30s at sandbox creation, most of it the Playwright system libraries, and
about 15s without them. Skip them with:

```bash
sbx create ... -e SBX_DEV_TOOLS_PLAYWRIGHT=0
```

An install kit rather than a prebaked image because kits cannot set one:
`container`, `image` and `dockerfile` are all rejected by `spec.specFileV2`, and
`sbx create --template` is CLI-only, so a custom image could not ride along with
`--kit`. At 30s, maintaining an image and tracking the upstream base is not
worth it.

## Failure behaviour

The core toolchain (Node, corepack, pnpm) runs under `set -e`: if it cannot be
installed, sandbox creation fails loudly rather than handing back a sandbox that
looks fine and is not. The optional extras (gh, trufflehog, apt packages,
Playwright libs) go through a `soft` helper that warns and continues, because a
transient 502 from a release host is not a reason to have no sandbox.

The startup command can never exit non-zero. `/etc/durable-startup.d/run.sh`
stops the whole chain on the first failure, which would take out the other
kits' startup commands too; an `EXIT` trap forces status 0 on every path. See
`claude-config-kit/README.md` for the same rule.

## Verified against

sbx 0.39.0, `docker/sandbox-templates:claude-code-docker` (Ubuntu 26.04,
aarch64), on cold sandboxes created against both league repositories.
