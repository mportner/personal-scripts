# Project Guidance

This file provides context and guidance for working with this project.

## Project Overview

This project is written primarily in javascript.

## Tools and Commands

- Use "npm install" or "yarn install" to install dependencies
- Use "npm test" or "yarn test" to run tests
- Check package.json for available scripts

## Development Workflow

1. Make changes to .js/.ts files
2. Run "npm install" if dependencies changed

## Coding Style

- Follow the existing code style in the project

## Testing Approach

- Run "npm test" to execute tests

## Environment Persistence

This sandbox has a persistent environment file at `/etc/sandbox-persistent.sh`.

```bash
# A fenced block whose contents must not be read as headings.
## Additional Notes
echo "export VAR_NAME=value" >> /etc/sandbox-persistent.sh
```

## Network access

Egress is filtered by a proxy. A blocked request fails with a 403.

## Git Authentication

`GH_TOKEN` is a placeholder the proxy substitutes.

## Git workspace mode

```bash
if [ -d /run/sandbox/source ]; then echo "clone mode"; else echo "direct mode"; fi
```

## Additional Notes

- Always read relevant files before making changes
- Run tests after making modifications
- You have sudo permissions, so you can install necessary packages
- npm, pip and uv are already available for package management

## Claude Code: Environment Persistence

The `CLAUDE_ENV_FILE` environment variable is set to `/etc/sandbox-persistent.sh`.

<!-- sbx:kits-section start -->
## Kits

The following kits are installed. Read the matching file under
`/workspace/../kits-agent-context/` only when a kit becomes relevant.

- **Research Sandbox** (`claude-research`) - See `/workspace/../kits-agent-context/claude-research.md`.
<!-- sbx:kits-section end -->
