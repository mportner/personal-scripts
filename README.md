# personal-scripts

Personal macOS shell scripts and configuration, kept in one repo so a new
machine is one `git clone` and one `./setup.sh` away.

Everything here targets **bash 3.2** — the version macOS ships — so it runs on a
stock system with no interpreter to install first.

## Contents

| Path | What it is |
| --- | --- |
| [`bin/brew-upgrade-safe.sh`](bin/brew-upgrade-safe.sh) | `brew upgrade` that holds casks back until a release has soaked upstream |
| [`shell/sbx-kit-wrapper.zsh`](shell/sbx-kit-wrapper.zsh) | zsh wrapper making a default `--kit` apply to `sbx run claude` |
| [`claude-config-kit/`](claude-config-kit/) | an [sbx](https://github.com/docker/sandboxes) mixin kit carrying a Claude Code status line and settings into every sandbox |
| [`setup.sh`](setup.sh) | installer — symlinks `bin/`, sources `shell/` |
| [`uninstall.sh`](uninstall.sh) | reverses `setup.sh` |

## Install

```bash
git clone https://github.com/mportner/personal-scripts.git ~/personal-scripts
cd ~/personal-scripts
./setup.sh
```

`setup.sh` does two things:

- **`bin/`** — symlinks each executable into `~/.local/bin` with a known script
  extension (`.sh`, `.bash`, `.zsh`, `.py`, `.rb`, `.pl`) stripped, so
  `brew-upgrade-safe.sh` becomes the command `brew-upgrade-safe`.
- **`shell/`** — adds a marked block to `~/.zshrc` that puts that directory on
  `PATH` and `source`s every fragment. Fragments define shell functions, so they
  must be sourced rather than executed, which is why they are never symlinked
  onto `PATH`.

It prompts before touching `~/.zshrc` and backs the file up first. If it finds
one of its marker comments without the matching partner — a half-removed block,
or a hand-edited one — it refuses to touch the file rather than guess where the
block ends. Preview without changing anything:

```bash
./setup.sh --dry-run
```

Re-running is safe and is how you pick up new scripts: it converges on the
current contents of both directories — new scripts are linked, moved ones
repointed, links to deleted scripts pruned, and the rc block rewritten if it has
drifted. Only symlinks pointing into this repo are ever touched, so it cannot
disturb entries another installer owns in `~/.local/bin`.

Set `PERSONAL_SCRIPTS_BIN` to link somewhere other than `~/.local/bin`.

### Without the sandbox wrapper

On a machine with no [`sbx`](https://github.com/docker/sandboxes), skip the
wrapper and install everything else:

```bash
./setup.sh --no-sandbox
```

Because re-running converges, this doubles as the way to change your mind
later. Adding the flag on a machine that already has the wrapper removes its
`source` line; dropping the flag puts it back. Neither touches anything else.

## Uninstall

```bash
./uninstall.sh
```

All or nothing: it removes every symlink pointing into this repo and offers to
strip the managed block from `~/.zshrc`. To remove just the sandbox wrapper and
keep the rest, re-run `./setup.sh --no-sandbox` instead.

## Requirements

- macOS with [Homebrew](https://brew.sh)
- `zsh` (the macOS default) for the `shell/` fragments
- `jq` — required by `brew-upgrade-safe` and the status line: `brew install jq`
- [`gh`](https://cli.github.com), optional — `brew-upgrade-safe` uses it for an
  authenticated GitHub API rate limit (5000/hr rather than 60/hr), which matters
  because it makes one API call per gated package
- [`sbx`](https://github.com/docker/sandboxes), optional — only for
  `claude-config-kit` and the wrapper

## The scripts

### `brew-upgrade-safe`

Upgrades formulae immediately but holds casks back until their definition has
been in the Homebrew tap for a cooldown window (default 5 days), so you are not
first to install a broken release. It builds the whole plan first, prints it in
three sections — no cooldown, past cooldown, holding back — and asks before
changing anything.

```bash
brew-upgrade-safe              # show the plan, then confirm
brew-upgrade-safe --dry-run    # plan only
brew-upgrade-safe -d 10        # 10-day cooldown
```

Security-critical packages are listed in `NEVER_GATE` inside the script and
always upgrade immediately — for a browser, a delayed security patch is a bigger
risk than a bad release. Edit that list, and `GATED_FORMULAE` next to it, to
taste.

The cooldown clock measures **packaging**, not the upstream release: it starts
at the tap commit that published the version. For a cask tracking a delayed
release channel the version can already be weeks old upstream, which is what
`NEVER_GATE` is the escape hatch for.

### `claude-config-kit`

An sbx mixin kit that installs a three-line Claude Code status line and a set of
preferred settings into every sandbox created with it. See its
[README](claude-config-kit/README.md) for the design notes and the extracted kit
spec reference.

> **If you are not the author:** the shipped `settings.json` enables the
> `devpowers` plugin from the `mportner/agentpowers` marketplace, which is a
> private repository and will not resolve for you. Remove the
> `enabledPlugins` and `extraKnownMarketplaces` entries from
> `claude-config-kit/files/home/.claude-config-kit/settings.json` — the status
> line and every other setting work without them.

### `sbx-kit-wrapper.zsh`

`sbx` has no config file or environment variable for a default kit; `--kit` is a
per-invocation flag. This wrapper supplies it, so `sbx run claude` behaves as if
`claude-config-kit` were the default. Anything that is not `run`/`create`, and
any invocation that already passes `--kit`, is passed straight through
untouched.

The kit path is resolved from the fragment's own location, so the repo works
wherever you clone it. Override with `SBX_DEFAULT_KIT` before sourcing. If the
kit directory is missing it warns and runs `sbx` unmodified, rather than
silently dropping the flag.

This is the one piece `./setup.sh --no-sandbox` leaves out.

## License

[MIT](LICENSE)
