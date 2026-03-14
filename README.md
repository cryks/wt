# wt

## Overview

`wt` is a small local Bash wrapper around `git worktree` that makes creating, navigating, merging, and removing linked worktrees fast and safe.

It works with **any Git repository**. Node.js projects get additional conveniences (lockfile-based package manager detection and automatic dependency installation), but those features are skipped gracefully when no supported lockfile or `packageManager` field is found. You can use `wt` on a Go, Python, Rust, or plain-text repository with no changes.

Core design principles:

- uses a sibling worktree root at `<repo>__worktrees/`
- keeps the Git branch name separate from the filesystem handle
- copies common local env files only when the source exists and the target is missing
- installs dependencies only when it can confidently detect the package manager
- never starts a dev server or pushes to a remote

## Install

Add this repository's `bin` directory to your `PATH`:

```bash
export PATH="$(pwd)/bin:$PATH"
```

### Shell wrapper (recommended)

Source the shell helper to get `cd` behavior in Bash or zsh:

```bash
source "$(pwd)/shell/wt.bash"
```

With the sourced wrapper:

- `wt cd <name>` changes into the linked worktree in your current shell
- `wt new <branch>` and `wt new` (interactive mode) also move you into the new worktree
- `wt rm` with no target hops back to the primary worktree before removing the current linked worktree
- `wt merge` moves you back to the primary worktree after a successful merge
- `wt sync` keeps you in the current linked worktree after syncing from primary

Here, "primary" means the repository-root checkout managed by `git worktree`, using whatever branch is currently checked out there.

The wrapper resolves the bundled `bin/wt` directly, so it does not depend on `command wt` lookup. The `wt --help` output describes the binary itself, while the sourced wrapper adds shell-level `cd` behavior on top.

## Prerequisites

- **Required**: `git`, `bash`
- **Required for AI features**: [OpenCode](https://github.com/opencode-ai/opencode) (`opencode` on `PATH`)
- **Required for portless integration**: `portless` on `PATH`, `python3`
- **Optional**: a supported Node.js package manager (`pnpm`, `npm`, or `bun`) for automatic dependency installation

## Commands

### `wt new [branch]`

Create a linked worktree for a branch.

```bash
wt new feature/test
```

When called without a branch argument in an interactive terminal, `wt new` enters an AI-assisted interactive flow:

1. Prompts you to describe what you want to do in the new worktree
2. Uses OpenCode to suggest a branch name based on your description
3. Lets you accept or edit the suggested name
4. Asks whether to launch OpenCode in the new worktree with your original description as the prompt

```bash
wt new
# What do you want to do in this worktree? add dark mode support
# Branch name [feat/dark-mode]: <Enter to accept, or type a different name>
# Launch opencode with this prompt? (y/n)
```

### `wt cd <branch-or-handle>`

Print the absolute path for a linked worktree. With the shell wrapper sourced, this also changes your working directory.

```bash
wt cd feature/test
```

### `wt open <branch-or-handle>`

Print the absolute path for a linked worktree (same resolution as `wt cd`, without the shell wrapper's `cd` behavior).

```bash
wt open feature/test
```

### `wt ls`

List the primary checkout and all linked worktrees with their branch, handle, type, and state.

```bash
wt ls
```

### `wt merge`

Merge the current linked worktree's branch into the branch currently checked out in the primary worktree, then clean up (remove the worktree and delete the branch).

```bash
wt merge
```

The merge strategy is:

1. If the primary branch has no new commits, fast-forward directly.
2. Otherwise, merge the primary branch into the feature branch first (reverse merge) to keep the feature branch safe from conflicts, then fast-forward the primary branch.
3. If the reverse merge produces conflicts, OpenCode (with the Maat agent) is launched to resolve them automatically. If AI resolution fails, the merge is aborted cleanly and the worktree is left intact.

### `wt sync`

Merge the branch currently checked out in the primary worktree into the current linked worktree, keeping the worktree and branch intact.

```bash
wt sync
```

The sync strategy is:

1. If the current worktree branch can be fast-forwarded to the primary branch, do that directly.
2. Otherwise, merge the primary branch into the current worktree branch.
3. If that merge produces conflicts, OpenCode (with the Maat agent) is launched to resolve them automatically. If AI resolution fails, the merge is aborted cleanly and the worktree is left intact.

### `wt rm [--force] [branch-or-handle]`

Remove a linked worktree conservatively.

```bash
wt rm                        # remove current worktree (shell wrapper only)
wt rm feature/test           # remove by branch or handle
wt rm --force                # remove even if dirty
wt rm --force feature/test
```

### `wt init`

Generate or update `.vscode/launch.json` for the current worktree with a Chrome DevTools attach configuration derived from the portless URL.

```bash
wt init
```

### `wt b [branch-or-handle]`

Open the current or requested worktree in a Chrome-compatible debug browser, deriving the URL from portless. Reuses an existing debug browser when possible.

```bash
wt b                   # current worktree
wt b feature/test      # specific worktree
```

## Safety

`wt` refuses or avoids several behaviors on purpose:

- it must be run from inside the repository you want to manage
- it will not delete the primary worktree
- it refuses locked worktrees in v1
- it refuses dirty worktrees unless you pass `--force`
- when a removed linked worktree is clean, it also tries `git branch -d`; with `--force`, it uses `git branch -D`
- it does not symlink `node_modules` or share generated framework directories
- `wt merge` refuses dirty worktrees and branches with no commits ahead
- `wt merge` merges the primary branch into the feature branch first to keep it safe from conflicts
- `wt merge` uses AI to resolve conflicts, and aborts cleanly if resolution fails
- `wt merge` never pushes to a remote
- `wt sync` refuses dirty worktrees and refuses to run when the primary branch has no commits ahead of the current linked branch
- `wt sync` merges the primary branch into the current linked worktree and keeps that worktree in place
- `wt sync` uses AI to resolve conflicts, and aborts cleanly if resolution fails
- real `cd` behavior requires sourcing `shell/wt.bash`, because a subprocess cannot change the parent shell directory

## Package manager detection

Detection is conservative and lockfile-first:

| Detected file | Install command |
|---|---|
| `pnpm-lock.yaml` | `pnpm install --prefer-offline` |
| `package-lock.json` | `npm install --prefer-offline` |
| `bun.lock` or `bun.lockb` | `bun install` |
| `package.json` `packageManager` field | corresponding manager |

If nothing is detected, dependency installation is skipped with an explicit message. This is the expected behavior for non-Node.js repositories.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `WT_BRANCH_NAME_MODEL` | `opencode-go/kimi-k2.5` | OpenCode model used for AI branch name suggestion in `wt new` interactive mode |
| `WT_MERGE_MODEL` | `opencode-go/glm-5` | OpenCode model used for AI merge conflict resolution |
| `WT_NEW_WORKTREE_AGENT` | `Build` | OpenCode agent used when `wt new` launches an interactive session in the new worktree |
| `WT_DEBUG_PORT` | `9222` | Chrome remote debugging port for `wt b` and `wt init` |
| `WT_DEBUG_USER_DATA_DIR` | `~/.vscode/chrome` | Chrome user data directory for the debug browser |
| `WT_CHROME_BIN` | auto-detected | Path to a Chrome-compatible browser binary |

## Portless integration

`wt` does not depend on `portless`, and it does not start `portless` or any app process.

When `wt new` creates a worktree in a repository whose `package.json` `scripts.dev` is a portless command, `wt` automatically runs `wt init` to set up the debug browser configuration. The portless URL for the linked worktree is derived from the app name, so each worktree gets a distinct local URL when you start the app yourself.

`wt b` and `wt init` both require portless to be available on `PATH`.

## Testing

Run the smoke test suite:

```bash
bash tests/smoke.sh
```

Tests use temporary repositories and fake binaries for external dependencies (OpenCode, portless, Chrome), so they run without network access or real browser instances.
