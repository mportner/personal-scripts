# Security Policy

These are personal scripts, published so a new machine is one `git clone` away
and so the approach is easy to share. They are maintained on a best-effort
basis by one person. Please calibrate expectations accordingly — but do report
things, because these scripts run on other people's machines.

## Supported versions

Only the current `main` branch. There are no releases or version branches, and
fixes are not backported to older commits.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Use GitHub's private reporting instead:
[**Report a vulnerability**](https://github.com/mportner/personal-scripts/security/advisories/new).
That opens a private thread visible only to you and the maintainer.

Expect an acknowledgement within about a week. If a report is valid, the fix
lands on `main` and the advisory is published once it is out.

## What is in scope

Anything where running this repo as documented could compromise the machine it
runs on:

- `setup.sh` / `uninstall.sh` — they edit `~/.zshrc` and create symlinks in
  `~/.local/bin`. Path handling, symlink handling, and the marker-block logic
  that rewrites the rc file are the sensitive parts.
- `bin/brew-upgrade-safe.sh` — it decides which Homebrew packages to upgrade.
  A flaw that causes it to skip a security update, or to upgrade something it
  should have held back, is in scope.
- `claude-config-kit/` — the startup command merges into
  `~/.claude/settings.json` inside a sandbox container.
- `.github/workflows/` — CI supply-chain issues.

## What is out of scope

- The kit's `settings.json` enables a plugin from a private marketplace
  (`mportner/agentpowers`) that will not resolve for anyone else. This is known
  and documented in the READMEs; it fails closed and is not a vulnerability.
- Anything requiring an attacker to already have write access to your machine
  or your GitHub account.
- Vulnerabilities in Homebrew, `sbx`, `jq`, `gh`, or Claude Code themselves.
  Please report those upstream.

## For anyone auditing

Everything here is shell. `setup.sh`, `uninstall.sh`, and
`bin/brew-upgrade-safe.sh` target bash 3.2 (what macOS ships);
`claude-config-kit/files/home/.claude/statusline.sh` is POSIX `sh`. CI runs
`shellcheck` on all of them plus the shell embedded in the kit spec. Note that
shellcheck is a correctness linter, not a security scanner, and CodeQL has no
shell analyzer — so the scripts themselves are covered by review, not by an
automated scanner.
