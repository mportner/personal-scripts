# claude-config-kit

An [sbx](https://github.com/docker/sandboxes) **mixin kit** that carries a
custom Claude Code status line and a set of preferred settings into every
sandbox created with it, surviving sandbox recreation.

```bash
sbx run claude --kit ~/personal-scripts/claude-config-kit
```

Or source `../shell/sbx-kit-wrapper.zsh` and just run `sbx run claude`.

## What it installs

| Path in container | Source | How |
| --- | --- | --- |
| `/home/agent/.claude/statusline.sh` | `files/home/.claude/statusline.sh` | static copy at container creation |
| `/home/agent/.claude-config-kit/settings.json` | `files/home/.claude-config-kit/settings.json` | static copy at container creation |
| `/home/agent/.claude/settings.json` | merged by the startup command | `jq` recursive merge on every container start |

Settings merged in:

```json
{
  "tui": "fullscreen",
  "syntaxHighlightingDisabled": false,
  "effortLevel": "high",
  "autoCompactEnabled": false,
  "env": { "CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION": "1" },
  "attribution": { "commit": "", "pr": "" },
  "enabledPlugins": {
    "frontend-design@claude-plugins-official": true,
    "devpowers@agentpowers": true
  },
  "extraKnownMarketplaces": { "agentpowers": { "source": { "source": "github", "repo": "mportner/agentpowers" } } },
  "statusLine": { "type": "command", "command": "/home/agent/.claude/statusline.sh", "padding": 0 }
}
```

These are a **fixed snapshot** of the host `~/.claude/settings.json`, not a live
mirror. Edit `files/home/.claude-config-kit/settings.json` to change them, then
recreate any sandbox that should pick the change up.

> Note that `mportner/agentpowers` is a private repository, so for anyone else
> the `devpowers@agentpowers` plugin will not resolve. Drop the `enabledPlugins`
> and `extraKnownMarketplaces` keys from the fragment; nothing else in the kit
> depends on them.

`statusline.sh` is a byte-identical copy of the host's own status line script,
`~/.claude/statusline-command.sh` (md5 `d2b8d87d5ed159628d072af0f29f8970`), which
is what the host `settings.json` points at. `files/` is copied into the container,
so it cannot be a symlink to that file. After editing the host script, re-copy it:

```bash
cp ~/.claude/statusline-command.sh \
   ~/personal-scripts/claude-config-kit/files/home/.claude/statusline.sh
```

Sandboxes pick the change up on their next creation, not on restart, because the
copy happens at container creation.

## Why a startup command rather than shipping settings.json directly

`~/.claude/settings.json` has several writers. The built-in `claude` kit creates
it with `defaultMode`, `bypassPermissionsModeAccepted`, `themeId`,
`alwaysThinkingEnabled` and `skipDangerousModePermissionPrompt`, and Claude Code
itself writes to it mid-session. Shipping the file statically would clobber all
of that, so the kit ships a *fragment* and merges it with `jq -s '.[0] * .[1]'`
— a recursive merge, so nested objects like `env` merge key-by-key instead of
being replaced.

The merge command must never exit non-zero: `/etc/durable-startup.d/run.sh`
iterates the registered startup commands and `exit $rc`s on the first failure,
which would silently drop every command after it, including other kits'. An
`EXIT` trap forces status 0 on all paths.

## Verified behaviour

Tested against sbx 0.38.0 on a throwaway sandbox:

- `sbx kit validate ./claude-config-kit` passes; `inspect` reports
  `1 startup, 2 home files`.
- A fresh `sbx create claude --kit ...` lands both files (exec bit preserved,
  md5 intact) and merges settings before the agent starts. Base-kit keys survive.
- The status line renders correctly inside the container.
- Survives `sbx stop` + restart; the merge re-runs and is idempotent
  (`statusLine` appears exactly once, file byte-identical across re-runs).
- Failure modes all exit 0 and leave no temp files: unparseable `settings.json`
  (left untouched), missing `statusline.sh` (settings merged, no `statusLine`
  key), missing fragment (status line only), no `settings.json` at all (created).

## Applying it to an existing sandbox

You cannot. `sbx kit add` refuses this kit:

```
ERROR: kit "claude-config" declares setup.startup, which the kit-add recreate
flow does not yet apply; recreate the sandbox from scratch via `sbx rm` +
`sbx create --kit` to use this kit
```

`kit add` currently supports only env variables, install commands, and network
allow rules. Kits with startup commands, `initFiles`, or `files` must be applied
at creation time. Note that `sbx rm` also drops the sandbox's persistent volumes
(`~/.claude/projects`, `sessions`, `todos`, `shell-snapshots`, `statsig`), so
recreating loses Claude Code session history. A bind-mounted workspace on the
host is unaffected.

To apply the settings to a *running* sandbox without recreating it, run the
merge imperatively — it is the same logic, but it lives on the container overlay
and dies on recreate.

## Kit spec reference (sbx 0.38.0)

The schema is not published in the CLI help; it is embedded in the `sbx` binary
and was extracted from there, then confirmed with `sbx kit validate`.

```
claude-config-kit/
├── spec.yaml           # required
└── files/              # optional, auto-discovered, not declared in spec.yaml
    ├── home/           #   → /home/agent/
    └── workspace/      #   → the workspace directory
```

Top level: `schemaVersion` (`"2"` current, `"1"` still loads with a deprecation
warning), `kind` (`sandbox` or `mixin`), `name`, `version`, `displayName`,
`description`, `extends`, `publishedPorts`.

Sections: `permissions.network.allow` / `.deny`, `environment.variables`,
`credentials`, `setup.install`, `setup.startup`, `setup.initFiles`,
`agentInstructions`, `agentContext`.

| | `setup.install` | `setup.startup` |
| --- | --- | --- |
| Form | shell string, run via `sh -c` | argv array, e.g. `["sh", "-c", "..."]` |
| When | once, at container creation | every container start |
| Default user | `"0"` (root) | `"1000"` (agent) |
| Fields | `command`, `user`, `description` | `command`, `user`, `background`, `description` |

`user` accepts a name (`"agent"`, `"root"`) as well as a uid string.

Kits compose in `--kit` order and are appended after the base agent's own
sections, so this kit's startup command runs after the `claude` kit has created
`settings.json`. Startup commands are materialised as
`/etc/durable-startup.d/<NNN>-startup-<kit-name>/<NNN>-cmd.sh`; the log is
`/var/log/sbx-kit-startup.log`.

Packaging: `sbx kit pack <dir>` (v2 → `.tar.gz`, v1 → `.zip`), then
`sbx kit push <dir> <registry/repo:tag>` to share. Note that
`sbx settings get kit.allowedSources` defaults to `["docker.io/"]`, so pushing
elsewhere means widening that first.
