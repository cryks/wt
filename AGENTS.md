# AGENTS.md — wt contributor guide for AI agents

## Project structure

```
bin/wt           # Main CLI — single Bash script, all logic lives here
shell/wt.bash    # Shell wrapper for cd behavior (bash + zsh)
tests/smoke.sh   # End-to-end test suite with fake binaries
README.md        # User-facing documentation
AGENTS.md        # This file — internal design notes for AI agents
```

There is no build step, no transpilation, and no package.json for this repository itself. The `bin/wt` script is both source and executable.

## Architecture decisions not obvious from source

### Why a single Bash file

All commands live in `bin/wt` as functions (`cmd_new`, `cmd_rm`, `cmd_merge`, etc.). This is intentional: `wt` is distributed by adding `bin/` to `PATH`, so a single self-contained script avoids library resolution issues. Helper functions like `normalize_handle`, `detect_package_manager`, and `list_worktrees` are defined before the command functions that use them.

### Embedded Python helpers

Several functions shell out to inline Python scripts (heredocs) for tasks that are painful in pure Bash: JSON parsing, portless `scripts.dev` inspection, Chrome DevTools protocol interaction, OpenCode JSON output extraction, and terminal emulation in tests. Python 3 is the only non-Bash runtime dependency. These inline scripts are deliberately NOT extracted into separate `.py` files — they are coupled to the Bash function that calls them and share no state.

### Worktree layout: `<repo>__worktrees/<handle>`

Linked worktrees are stored in a sibling directory named `<repo>__worktrees/` (not inside the repo). This avoids polluting the repository with worktree directories and keeps the layout predictable. The `__worktrees` suffix is hardcoded in `get_worktree_root`.

### Handle vs. branch

A "handle" is the filesystem-safe name derived from a branch name by `normalize_handle`. The transformation: lowercase, replace `/` and whitespace with `-`, collapse repeated dashes, strip leading/trailing dashes. For example, `feature/Add-Login` becomes `feature-add-login`. The handle is used as the directory name under `__worktrees/`. Commands that accept a `branch-or-handle` argument resolve both — `resolve_worktree_target` checks handle matches first, then branch matches, and errors on ambiguity.

### Primary branch detection

`wt` does NOT hardcode `main` or `master`. The "primary branch" is whatever branch is currently checked out in the primary (main repo root) worktree, determined by `get_primary_branch` via `git branch --show-current`. This means:

- If you switch the primary worktree to `release/1.0`, that becomes the merge target for `wt merge`.
- A detached HEAD in the primary worktree makes `wt merge` refuse to operate.

### Merge strategy

`wt merge` uses a two-step approach to keep the feature branch safe:

1. Try fast-forward from the primary worktree (`git merge --ff-only feature-branch`).
2. If that fails, reverse-merge: merge the primary branch INTO the feature branch first (resolving conflicts on the feature side), then fast-forward the primary branch.

This design ensures the primary branch never has a dirty merge commit — the feature branch absorbs any conflict resolution. AI conflict resolution (OpenCode with the Maat agent) only runs during the reverse merge step. If AI fails, `git merge --abort` restores the feature branch to its pre-merge state.

### OpenCode integration points

There are three distinct OpenCode integration points, each using a different model and protocol:

1. **Branch name suggestion** (`suggest_branch_name_with_opencode`): Uses `opencode run --format json` with `WT_BRANCH_NAME_MODEL` (default: `opencode-go/kimi-k2.5`). Parses newline-delimited JSON events, extracting `type: "text"` parts. The prompt constrains the output to a single valid `git check-ref-format` branch name. The `run` subcommand accepts `--dir` to set the working directory.

2. **Merge conflict resolution** (`merge_feature_with_primary`): Uses `opencode <project-path> --agent "Maat" --model "$WT_MERGE_MODEL"`. This is an interactive agent session, not `run` mode. The project path is passed as a positional argument (not `--dir`, which is only valid for the `run` and `attach` subcommands). The agent is instructed to examine conflicts, resolve them, stage files, and run `git merge --continue`.

3. **New worktree autostart** (`launch_opencode_in_worktree`): Uses `opencode <project-path> --agent "$WT_NEW_WORKTREE_AGENT" --prompt "$goal"`. The project path is the first positional argument. Launches an interactive OpenCode session in the new worktree with the user's original goal description, attached to the terminal's stdin/stdout.

### Shell wrapper design (`shell/wt.bash`)

The wrapper defines a `wt` shell function that intercepts `cd`, `new`, `rm`, and `merge` subcommands and adds shell-level behavior (actually changing the working directory). Other commands pass through to `bin/wt` unchanged.

Key subtlety: `wt rm` without arguments must `cd` back to the primary worktree BEFORE calling `bin/wt rm`, because you cannot remove a worktree while standing inside it. The wrapper detects this situation, resolves the primary worktree path, `cd`s there, then delegates removal. For dirty worktrees, the wrapper intentionally does NOT `cd` away first — it lets `bin/wt rm` fail with the expected error while keeping the user in their current directory.

### Portless URL derivation

When a repo's `package.json` `scripts.dev` uses portless, `wt` derives the app name through `inspect_portless_dev_script` (a Python parser that handles both `portless <name> <cmd>` and `portless run [--name <name>] -- <cmd>` forms). If the name is explicit, it is used directly. If only `portless run` without `--name` is found, the name is inferred from the nearest `package.json` `name` field or the repository directory name (`infer_portless_base_name`).

The actual URL is obtained by running `portless get <name>` inside the worktree directory. Linked worktrees get distinct URLs because portless resolves names relative to the working directory.

## Testing conventions

- Tests are in `tests/smoke.sh` — a single Bash file with test functions and assertions.
- External dependencies are replaced with fake binaries created at test time (`make_fake_opencode_bin`, `make_fake_portless_bin`, `make_fake_browser_bin`, etc.).
- Tests that require an interactive terminal use `run_in_pty`, which spawns a pseudo-terminal via Python.
- Terminal output with ANSI escape sequences is rendered via `render_terminal_output` for assertions.
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
| `WT_NEW_WORKTREE_AGENT` | `Sisyphus (Ultraworker)` | OpenCode agent for new worktree autostart |
| `WT_DEBUG_PORT` / `WT_DEBUG_PORT_DEFAULT` | `9222` | Chrome remote debugging port |
| `WT_DEBUG_USER_DATA_DIR` | `~/.vscode/chrome` | Chrome profile directory for debug browser |
| `WT_CHROME_BIN` | auto-detected | Chrome binary override |
| `ENV_CANDIDATES` | `.env`, `.env.local`, `.env.development.local` | Files copied from primary to new worktree |
| `WT_MANAGED_LAUNCH_NAME` | `wt: attach browser` | Name of the managed VS Code launch configuration |

## Documentation maintenance rules

**When you change code in this repository, you MUST update the relevant documentation:**

1. **README.md** — Update if any user-visible behavior changes: new commands, changed flags, different defaults, new prerequisites, changed safety guarantees, or updated environment variables.

2. **AGENTS.md** (this file) — Update if any internal design changes: new helper functions, changed merge strategy, new OpenCode integration points, new environment variables, changed worktree layout, new testing patterns, or architectural decisions that would not be obvious from reading the source alone.

3. **Both files** — Update if a change affects both user-facing behavior and internal design (e.g., adding a new command requires a README section and an AGENTS.md note about its implementation approach).

Do not let documentation drift from the implementation. When in doubt, update both files.
