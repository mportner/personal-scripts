# dev-tools-kit

An [sbx](https://docs.docker.com/ai/sandboxes/) **mixin kit** that puts the
toolchain these projects expect into a sandbox before the agent starts, so the
agent never has to install its own.

```bash
sbx create claude \
  --kit ~/personal-scripts/claude-config-kit \
  --kit ~/personal-scripts/dev-tools-kit .
```

Or source `../shell/sbx-kit-wrapper.zsh` and just run `sbx create claude .`,
which supplies both.

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
| Node | 24.20.0 | nodejs.org tarball → `/usr/local` | `SHASUMS256.txt` |
| npm | 11.19.0 | bundled with Node | (as above) |
| pnpm | 11.22.0 baseline, per project thereafter | github.com release, standalone bundle | sha256 pinned in `spec.yaml` |
| gh | 2.98.0 | github.com release | `gh_*_checksums.txt` |
| trufflehog | 3.97.1 | github.com release | `trufflehog_*_checksums.txt` |
| shellcheck, xz-utils, wget, file, tree, unzip | distro | apt | apt signatures |
| Playwright chromium system libs | distro | apt | apt signatures |

Node unpacks over `/usr/local`, which precedes `/usr/bin` on the sandbox's PATH,
so the distro's Node 22 is shadowed rather than removed and nothing in the base
image is disturbed.

`docker` and `docker compose` are already in the base image (29.7.1 / v5.4.0)
and need nothing from this kit.

## pnpm: standalone, not corepack and not npm

The two projects pin different pnpm versions, league-bot `pnpm@11.17.0` and
league-service `pnpm@11.7.0`, so a single global pnpm would be wrong for at
least one of them. Corepack is the usual answer to that and is the wrong one
here: it is deprecated upstream and on its way out of the Node distribution,
the base image's copy (0.24.0) is too old to fetch a modern pnpm, and reaching
a usable one meant lifting it out of the Node tarball and then working around
`corepack enable` targeting root-owned `/usr/bin`.

pnpm has since absorbed the only feature corepack was needed for.
`manage-package-manager-versions` is on by default: pnpm reads `packageManager`
and switches itself to that exact version, caching it under `~/.cache/pnpm`. So
one pinned binary still gives every project the version it asks for:

```
$ cd /tmp           && pnpm --version   → 11.22.0    (PNPM_VERSION in spec.yaml)
$ cd league-bot     && pnpm --version   → 11.17.0    (its packageManager)
$ cd league-service && pnpm --version   → 11.7.0     (its packageManager)
```

The binary is the standalone release tarball from GitHub, which is a
self-contained bundle: no corepack, no npm, and nothing fetched from a package
registry at install time. pnpm publishes no checksum manifest beside it, so the
sha256 is pinned in `spec.yaml` for both architectures rather than fetched.
Recompute on bump:

```bash
curl -fsSL https://github.com/pnpm/pnpm/releases/download/v<VER>/pnpm-linux-arm64.tar.gz | shasum -a 256
```

It unpacks whole into `/usr/local/lib/pnpm` with a symlink onto PATH, because
the launcher resolves `dist/pnpm.mjs` relative to its own location and needs the
sibling `dist/` tree beside it. Node still bundles its own corepack, so
`/usr/local/bin/corepack` exists; nothing reaches it.

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

Nothing this kit installs goes through npm, npx or corepack. The four tools it
downloads directly (Node, pnpm, `gh`, trufflehog) are pinned to exact versions
and checked against a checksum, either the publisher's own manifest or, for
pnpm, a hash pinned in `spec.yaml`. Everything else is an apt package: signed
by the distro and versioned by it, so those track the Ubuntu repository rather
than a pin here. That constraint is why the
Playwright system libraries are apt-installed from Playwright's own list rather
than by running `playwright install-deps`: reaching that command means fetching
the playwright package first, at creation time, with no way to apply the
release-age window to it.

Note that npm counts `min-release-age` in **days** and pnpm counts
`minimumReleaseAge` in **minutes**, so the `5` in `.npmrc` and the `7200` in
`config.yaml` are the same five-day window rather than a disagreement.

`PNPM_VERSION` is the one pin needing a manual check on bump, because pnpm's own
self-download is not subject to the window. 11.22.0 was published 2026-08-15,
comfortably outside it; 11.24.0 was three days old at the time of writing and
would have violated it.

## node_modules isolation

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

A startup command gives each `node_modules` a private directory on the
container's writable layer instead. It derives the paths at runtime from
`$WORKSPACE_DIR`, so **one kit covers every project** rather than needing a
per-project variant:

```
$ findmnt | grep node_modules
/Users/mike/Repos/league-service/node_modules                       overlay
/Users/mike/Repos/league-service/packages/league-api/node_modules   overlay
  ... 6 packages, 4 .claude/worktrees, and .pnpm-store              overlay
```

`.pnpm-store` is in that list for a second reason: pnpm hardlinks out of the
store into `node_modules`, which only works within one filesystem. Leaving the
store on virtiofs while `node_modules` moved to the overlay turned every
package into a full copy, which is both slow and what exhausted the disk on the
first attempt.

The backing store is a plain directory, not a kit volume, because
`volumes[].path` takes no size and sbx gives one 488M, which `ENOSPC`s partway
through a real install. The overlay has ~18G, and its lifecycle is the one we
want anyway: it survives stop/start and dies with `sbx rm`.

Clone-mode sandboxes are skipped automatically. The loop only acts on
directories whose filesystem is `virtiofs`, and a `--clone` workspace is already
on a container volume.

### What this changes for you

The host `node_modules` is invisible inside the sandbox, so a fresh
`pnpm install` is needed once per sandbox. Measured on a cold sandbox:

| | league-service (1109 pkgs, 7 workspaces) | league-bot |
| --- | --- | --- |
| `pnpm install` | 4.7s | 3.8s |
| `pnpm typecheck` | 2.2s, 5/5 tasks | passes |
| `pnpm test` | | 194/194 passing |

Host tree afterwards: 7 darwin packages, 0 linux, lockfile unchanged.

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
