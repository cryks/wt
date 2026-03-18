# AGENTS.md — wt contributor guide for AI agents

## Project structure

```
bin/wt             # Main CLI entrypoint — sources internal Bash modules, then dispatches commands
lib/wt-core.sh     # Shared constants and foundational helpers
lib/wt-portless.sh # Portless parsing and URL derivation helpers
lib/wt-debug.sh    # VS Code launch.json + Chrome DevTools helpers
lib/wt-worktree.sh # Worktree inventory, target resolution, install/env helpers
lib/wt-new.sh      # Interactive wt new flow and OpenCode branch suggestion helpers
lib/wt-commands.sh # cmd_* handlers plus merge/sync helpers
shell/wt.bash      # Shell wrapper for cd behavior (bash + zsh)
tests/smoke.sh     # End-to-end test suite with fake binaries
README.md          # User-facing documentation
AGENTS.md          # This file — internal design notes for AI agents
```

There is no build step, no transpilation, and no package.json for this repository itself. `bin/wt` remains the executable entrypoint, but the implementation is split across sourced Bash modules under `lib/`.

## Architecture decisions not obvious from source

### Why sourced Bash modules

`wt` is still distributed by adding `bin/` to `PATH`, but `bin/wt` is now a thin entrypoint that resolves its own location, sources companion modules from `lib/`, and then dispatches to `cmd_*` functions. This keeps the runtime model simple while reducing the cognitive load of a single 1500-line script.

Modules are grouped by responsibility:

- `lib/wt-core.sh` for shared constants and foundational helpers
- `lib/wt-portless.sh` for portless parsing and URL derivation
- `lib/wt-debug.sh` for launch.json and debug-browser integration
- `lib/wt-worktree.sh` for worktree inventory, target resolution, and setup helpers
- `lib/wt-new.sh` for interactive `wt new` / OpenCode branch suggestion logic
- `lib/wt-commands.sh` for `cmd_*` handlers and merge/sync helpers

The CLI and wrapper contracts are intentionally unchanged: `shell/wt.bash` still shells out to `bin/wt`, and parseable stdout fields like `worktree_path: ...` remain stable.

### Embedded Python helpers

Several functions shell out to inline Python scripts (heredocs) for tasks that are painful in pure Bash: JSON parsing, portless `scripts.dev` inspection, Chrome DevTools protocol interaction, OpenCode JSON output extraction, and terminal emulation in tests. Python 3 is the only non-Bash runtime dependency. These inline scripts are deliberately NOT extracted into separate `.py` files — they are coupled to the Bash function that calls them and share no state.

### Worktree bootstrap copy rules

`wt new` bootstraps each linked worktree by copying selected local development entries from the primary checkout into the new worktree when the destination path does not already exist. The copy logic lives in `copy_env_candidates_from_notes` in `lib/wt-worktree.sh` and currently covers:

- the literal `.env` file from `ENV_CANDIDATES`
- any file or directory whose basename ends with `.local`
- any file or directory whose basename contains `.local.`

Pattern-based `.local` scanning is intentionally limited to the repo root and directories implied by tracked files. `git_tracked_directories` derives those directories from `git ls-files`, including ancestor directories, so local-only siblings such as `.agents/skills/foo-skill.local/` are copied when their parent directory is part of the tracked project tree.

Copies use `cp -R` so both files and directories are supported.

### Worktree layout: `<repo>__worktrees/<handle>`

Linked worktrees are stored in a sibling directory named `<repo>__worktrees/` (not inside the repo). This avoids polluting the repository with worktree directories and keeps the layout predictable. The `__worktrees` suffix is hardcoded in `get_worktree_root`.

### Handle vs. branch

A "handle" is the filesystem-safe name derived from a branch name by `normalize_handle`. The transformation: lowercase, replace `/` and whitespace with `-`, collapse repeated dashes, strip leading/trailing dashes. For example, `feature/Add-Login` becomes `feature-add-login`. The handle is used as the directory name under `__worktrees/`. Commands that accept a `branch-or-handle` argument resolve both — `resolve_worktree_target` checks handle matches first, then branch matches, and errors on ambiguity.

### Primary branch detection

`wt` does NOT hardcode `main` or `master`. The "primary branch" is whatever branch is currently checked out in the primary (main repo root) worktree, determined by `get_primary_branch` via `git branch --show-current`. This means:

- If you switch the primary worktree to `release/1.0`, that becomes the merge target for both `wt merge` and `wt sync`.
- A detached HEAD in the primary worktree makes both `wt merge` and `wt sync` refuse to operate.

### Merge and sync strategy

`wt merge` uses a two-step approach to keep the feature branch safe:

1. Try fast-forward from the primary worktree (`git merge --ff-only feature-branch`).
2. If that fails, reverse-merge: merge the primary branch INTO the feature branch first (resolving conflicts on the feature side), then fast-forward the primary branch.

This design ensures the primary branch never has a dirty merge commit — the feature branch absorbs any conflict resolution. AI conflict resolution (OpenCode with the Maat agent) only runs during the reverse merge step. The merge prompt and the dedicated `agent-defines/maat.md` instructions bias Maat toward the current worktree side when a conflict cannot be cleanly combined, and tell it to use `question` instead of inventing a fix when the right resolution is ambiguous. If AI fails, `git merge --abort` restores the feature branch to its pre-merge state.

`wt sync` reuses the same branch-integration path in the opposite user flow: it merges the primary branch into the current linked worktree, but does not remove the worktree or delete the branch afterward. `cmd_sync` first tries `git merge --ff-only <primary-branch>` in the current worktree, then falls back to the shared `merge_branch_into_current` helper for non-fast-forward merges and AI conflict resolution.

### Status and diff comparisons follow the current primary checkout

`wt status` and `wt diff` do NOT hardcode `main` or `master`. They compare linked worktrees against whatever branch is currently checked out in the primary worktree, and fall back to the primary `HEAD` commit when the primary checkout is detached.

- `wt status` on a linked worktree reports ahead/behind counts plus `sync_status` / `merge_status` derived from that current primary reference.
- `wt status` on the primary worktree switches modes and reports linked/stale worktree counts instead of branch comparison data.
- `wt diff` uses the merge-base form `primary...target`, so the patch shows target-side committed changes only, even when the primary branch has moved ahead.

This keeps review-style commands aligned with the same primary-worktree semantics already used by `wt merge` and `wt sync`.

### Stale worktree cleanup via `wt prune`

`wt prune` is a conservative wrapper around `git worktree prune --expire now`.

- Candidate detection comes from the same `list_worktrees` state model used by `wt ls` and `wt status`.
- It only targets linked worktrees whose state includes `missing` or `prunable`.
- Locked entries are reported but skipped.
- Branch refs are intentionally left alone; `wt prune` only cleans Git's stale worktree metadata.

### OpenCode integration points

There are three distinct OpenCode integration points, each using a different model and protocol:

1. **Branch name suggestion** (`suggest_branch_name_with_opencode`): Uses `opencode run --format json` with `WT_BRANCH_NAME_MODEL` (default: `opencode-go/kimi-k2.5`). Parses newline-delimited JSON events, extracting `type: "text"` parts. The prompt constrains the output to a single valid `git check-ref-format` branch name. The `run` subcommand accepts `--dir` to set the working directory.

2. **Merge conflict resolution** (`merge_branch_into_current`): Uses `opencode <project-path> --agent "Maat" --model "$WT_MERGE_MODEL"`. This is an interactive agent session, not `run` mode. The project path is passed as a positional argument (not `--dir`, which is only valid for the `run` and `attach` subcommands). The runtime prompt and `agent-defines/maat.md` instruct Maat to prefer the current branch/worktree side over the incoming primary-branch side when a conflict cannot be cleanly combined, to ask the user via `question` when the right resolution is ambiguous, and to run `GIT_EDITOR=true git merge --continue` so it does not block on an editor inside a TUI session even if Git tries to consult `GIT_EDITOR`. Both `wt merge` and `wt sync` reuse this helper.

3. **New worktree autostart** (`launch_opencode_in_worktree`): Uses `opencode <project-path> --agent "$WT_NEW_WORKTREE_AGENT" --prompt "$goal"`. The project path is the first positional argument. Launches an interactive OpenCode session in the new worktree with the user's original goal description, attached to the terminal's stdin/stdout.

### Shell wrapper design (`shell/wt.bash`)

The wrapper defines a `wt` shell function that intercepts `cd`, `new`, `rm`, and `merge` subcommands and adds shell-level behavior (actually changing the working directory). Other commands, including `sync`, pass through to `bin/wt` unchanged.

Key subtlety: `wt rm` without arguments must `cd` back to the primary worktree BEFORE calling `bin/wt rm`, because you cannot remove a worktree while standing inside it. The wrapper detects this situation, resolves the primary worktree path, `cd`s there, then delegates removal. For dirty worktrees, the wrapper intentionally does NOT `cd` away first — it lets `bin/wt rm` fail with the expected error while keeping the user in their current directory.

The wrapper also depends on `wt new` continuing to emit a parseable `worktree_path: ...` line on stdout. Human-readable headings, indentation, and TTY-only ANSI styling may be added around the summary, but that field name must remain stable so `_wt_output_field` can still `cd` into the created worktree. The wrapper-side parser trims leading indentation and strips ANSI sequences before matching output fields.

`wt new` folds the raw `git worktree add` output into a dedicated `Worktree` section and streams those lines immediately before later bootstrap tasks such as dependency installation. This avoids the confusing delay where setup progress would only appear after `pnpm install`/`npm install` finished.

### Portless URL derivation

When a repo's `package.json` `scripts.dev` uses portless, `wt` derives the app name through `inspect_portless_dev_script` (a Python parser that handles both `portless <name> <cmd>` and `portless run [--name <name>] -- <cmd>` forms). If the name is explicit, it is used directly. If only `portless run` without `--name` is found, the name is inferred from the nearest `package.json` `name` field or the repository directory name (`infer_portless_base_name`).

The actual URL is obtained by running `portless get <name>` inside the worktree directory. Linked worktrees get distinct URLs because portless resolves names relative to the working directory.

## Testing conventions

- Tests are in `tests/smoke.sh` — a single Bash file with test functions and assertions.
- External dependencies are replaced with fake binaries created at test time (`make_fake_opencode_bin`, `make_fake_portless_bin`, `make_fake_browser_bin`, etc.).
- Tests that require an interactive terminal use `run_in_pty`, which spawns a pseudo-terminal via Python.
- Terminal output with ANSI escape sequences is rendered via `render_terminal_output` for assertions.
- `wt new` output tests should preserve both layers of the contract: human-readable headings like `Worktree` / `Created worktree` / `Bootstrap`, and stable machine-readable `key: value` lines such as `worktree_path:` and `branch:`.
- Workflow command output (`wt status`, `wt diff`, `wt prune`, `wt init`, `wt b`, `wt merge`, `wt sync`, `wt rm`) may also use section headings so long as existing machine-readable lines and wrapper contracts remain intact.
- Visible subprocess output within workflow commands should be dimmed in TTY mode so `wt` summary lines remain visually primary.
- PTY-oriented `wt new` tests may assert ANSI-colored output via raw capture and then use `render_terminal_output` to normalize escape sequences before checking the rendered text.
- Missing/prunable stale-state tests may remove a linked worktree directory directly to let Git report it as stale, and locked-state tests may combine `git worktree lock` with that missing-path setup.
- Tests create temporary Git repositories with `make_repo` and clean up automatically (they live in `/tmp`).
- All test functions are listed at the bottom of the file and run sequentially.
- To run: `bash tests/smoke.sh`

When adding a new test:

1. Write a `test_*` function following the existing pattern.
2. Add the function name to the list at the bottom of `tests/smoke.sh`.
3. Use `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_file_exists`, `assert_file_missing` for assertions.

## Environment variables (internal)

These are used in `bin/wt` and can be overridden:

| Variable | Default | Purpose |
|---|---|---|
| `WT_BRANCH_NAME_MODEL` | `opencode-go/kimi-k2.5` | Model for AI branch name suggestion |
| `WT_MERGE_MODEL` | `opencode-go/glm-5` | Model for AI merge conflict resolution |
| `WT_NEW_WORKTREE_AGENT` | `Build` | OpenCode agent for new worktree autostart |
| `WT_DEBUG_PORT` / `WT_DEBUG_PORT_DEFAULT` | `9222` | Chrome remote debugging port |
| `WT_DEBUG_USER_DATA_DIR` | `~/.vscode/chrome` | Chrome profile directory for debug browser |
| `WT_CHROME_BIN` | auto-detected | Chrome binary override |
| `ENV_CANDIDATES` | `.env` | Literal entries copied from primary to new worktree before pattern-based local override copying |
| `WT_MANAGED_LAUNCH_NAME` | `wt: attach browser` | Name of the managed VS Code launch configuration |

## Documentation maintenance rules

**When you change code in this repository, you MUST update the relevant documentation:**

1. **README.md** — Update if any user-visible behavior changes: new commands, changed flags, different defaults, new prerequisites, changed safety guarantees, or updated environment variables.

2. **AGENTS.md** (this file) — Update if any internal design changes: new helper functions, changed merge strategy, new OpenCode integration points, new environment variables, changed worktree layout, new testing patterns, or architectural decisions that would not be obvious from reading the source alone.

3. **Both files** — Update if a change affects both user-facing behavior and internal design (e.g., adding a new command requires a README section and an AGENTS.md note about its implementation approach).

Do not let documentation drift from the implementation. When in doubt, update both files.
