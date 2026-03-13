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

Add this repository's `bin` directory to your `PATH`:

```bash
export PATH="$(pwd)/bin:$PATH"
```

Optional shell helper if you want `cd` behavior in Bash or zsh:

```bash
source "$(pwd)/shell/wt.bash"
```

After sourcing that file, `wt cd <name>` changes into the linked worktree in your current shell,
and `wt new <branch>` also moves you into the newly created worktree when it succeeds.
With the sourced wrapper, `wt rm` with no target hops back to the primary worktree before removing the current linked worktree.
Here, "primary" means the repository-root checkout managed by `git worktree`, using whatever branch is currently checked out there.
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

List the primary checkout and linked worktrees:

```bash
wt ls
```

Merge the current linked worktree into the branch currently checked out in the primary worktree and clean up:

```bash
wt merge
```

Remove a linked worktree conservatively:

```bash
wt rm
wt rm feature/test
wt rm --force
wt rm --force feature/test
```

## Safety

`wt` refuses or avoids a few behaviors on purpose:
- it must be run from inside the repository you want to manage
- it will not delete the primary worktree
- it refuses locked worktrees in v1
- it refuses dirty worktrees unless you pass `--force`
- when a removed linked worktree is clean, it also tries `git branch -d`
- with `wt rm --force`, it also uses `git branch -D`
- it does not symlink `node_modules` or share generated framework directories
- `wt merge` refuses dirty worktrees and branches with no commits ahead of the branch currently checked out in the primary worktree
- `wt merge` merges the current primary-worktree branch into the feature branch first to keep that branch safe from conflicts
- `wt merge` uses AI (OpenCode with the Maat agent) to resolve conflicts when they occur
- `wt merge` never pushes to a remote
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
