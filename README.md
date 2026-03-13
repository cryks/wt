# wt

## Overview

`wt` is a small local Bash wrapper around `git worktree` for Node.js repositories.

It keeps the behavior conservative:
- uses a sibling worktree root at `<repo>__worktrees`
- keeps the Git branch name separate from the filesystem handle
- copies a few common local env files only when the source exists and the target is missing
- installs dependencies only when it can confidently detect the package manager
- never starts a dev server

## Install

Add `/Users/rbr/work/wt/bin` to your `PATH`:

```bash
export PATH="/Users/rbr/work/wt/bin:$PATH"
```

Optional shell helper if you want `cd` behavior in Bash or zsh:

```bash
source "/Users/rbr/work/wt/shell/wt.bash"
```

After sourcing that file, `wt cd <name>` changes into the linked worktree in your current shell,
and `wt new <branch>` also moves you into the newly created worktree when it succeeds.
The wrapper resolves the bundled `bin/wt` directly, so it does not depend on `command wt` lookup.
The `wt --help` output still describes the binary itself, while the sourced wrapper adds shell-level `cd` behavior.

## Commands

Create a linked worktree for a branch:

```bash
wt new feature/test
```

Change into a linked worktree by branch or handle:

```bash
wt cd feature/test
```

Print the absolute path for a linked worktree:

```bash
wt open feature/test
```

List the main checkout and linked worktrees:

```bash
wt ls
```

Remove a linked worktree conservatively:

```bash
wt rm feature/test
wt rm --force feature/test
```

## Safety

`wt` refuses or avoids a few behaviors on purpose:
- it must be run from inside the repository you want to manage
- it will not delete the main worktree
- it will not delete branches in v1
- it refuses locked worktrees in v1
- it refuses dirty worktrees unless you pass `--force`
- it does not symlink `node_modules` or share generated framework directories
- real `cd` behavior requires sourcing `shell/wt.bash`, because a subprocess cannot change the parent shell directory

Package manager detection is conservative and lockfile-first:
- `pnpm-lock.yaml` -> `pnpm install --prefer-offline`
- `package-lock.json` -> `npm install --prefer-offline`
- `bun.lock` or `bun.lockb` -> `bun install`
- otherwise, `package.json` `packageManager` is used when present

If nothing is detected, dependency installation is skipped with an explicit message.

## Portless Note

`wt` does not depend on `portless`, and it does not start `portless` or any app process.

If a repository already uses `portless`, a linked worktree should still fit that workflow well because you can start the app yourself inside the new worktree after `wt new ...` finishes.
