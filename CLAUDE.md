# General

**No Em dashes**: Em dashes (—) should almost never be used within text unless there is really no sensible alternative. This applies to all text including code comments, documentation, commit messages, PR titles and descriptions, Issue titles and descriptions, comments, replies, and especially end user facing (UI) text. Prefer a period, semicolon, colon, or parentheses instead.

# Code Conventions

**File headers**: All new source files start with the header block below. This applies to new files only, not existing files you edit. Skip files whose format does not support comments (JSON, `.env`, lockfiles, etc.). The example uses a C-style multi-line comment; adapt it to the target file type's comment convention.

Substitute the placeholders as follows:

- `{{file_name}}`: the file's name.
- `{{created_date}}`: the current date in ISO `YYYY-MM-DD` format.
- `{{license}}`: the active project's license, derived from context (e.g. a LICENSE file or package metadata).
- `{{year}}`: the current year.
- `{{developer_name}}`: Michael Portner.

```typescript
/*
 * File:    {{file_name}}
 * Created: {{created_date}}
 * License: {{license}}
 *
 * Copyright (c) {{year}} {{developer_name}}
 */
```

# Git commits

Write every commit message following the Conventional Commits 1.0.0 spec
(https://www.conventionalcommits.org).

- Format: `<type>[optional scope]: <description>`, plus optional body and footer(s).
- Common types: feat, fix, docs, refactor, perf, test, build, ci, chore, revert.
- Breaking changes: append `!` after the type/scope (e.g. `feat!:`) and/or add a
  `BREAKING CHANGE:` footer.
- Description: imperative mood, lower case, no trailing period.
