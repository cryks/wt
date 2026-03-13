require_interactive_terminal() {
  [ -t 0 ] || die "wt new without a branch requires an interactive terminal. Use: wt new <branch>"
}

prompt_for_new_worktree_goal() {
  local goal

  while :; do
    IFS= read -e -r -p 'What do you want to do in this worktree? ' goal || die "Cancelled wt new"
    if [ -n "$goal" ]; then
      printf '%s\n' "$goal"
      return 0
    fi
    warn "Please describe what you want to do in the new worktree"
  done
}

build_branch_name_generation_prompt() {
  local repo_name goal
  repo_name=$1
  goal=$2

  cat <<EOF
You generate Git branch names for a local worktree helper.

Repository: $repo_name
User intent: $goal

Return exactly one Git branch name and nothing else.

Rules:
- Lowercase ASCII only
- Keep it short, specific, and descriptive
- Prefer prefixes like feat/, fix/, chore/, docs/, refactor/, or test/ when they fit
- Use only letters, numbers, /, -, and .
- No spaces, quotes, code fences, or explanations
- The output must be valid for git check-ref-format --branch
EOF
}

extract_text_from_opencode_json() {
  require_python3

  python3 - "$1" <<'PY'
import json
import sys

texts = []

for raw_line in sys.argv[1].splitlines():
    line = raw_line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Failed to parse OpenCode JSON output: {exc}")

    event_type = event.get("type")
    if event_type == "error":
        error = event.get("error") or {}
        data = error.get("data") or {}
        message = data.get("message") or error.get("name") or "OpenCode returned an error"
        raise SystemExit(message)

    if event_type != "text":
        continue

    part = event.get("part") or {}
    text = part.get("text")
    if isinstance(text, str):
        texts.append(text)

if not texts:
    raise SystemExit("OpenCode returned no text suggestion")

combined = "".join(texts).strip()
for line in combined.splitlines():
    candidate = line.strip()
    if candidate:
        print(candidate)
        raise SystemExit(0)

raise SystemExit("OpenCode returned an empty suggestion")
PY
}

suggest_branch_name_with_opencode() {
  local repo_root goal repo_name prompt raw_output suggestion
  repo_root=$1
  goal=$2

  require_command opencode
  repo_name=$(basename "$repo_root")
  prompt=$(build_branch_name_generation_prompt "$repo_name" "$goal")
  raw_output=$(opencode run --format json -m "$WT_BRANCH_NAME_MODEL" --dir "$repo_root" "$prompt") || die "OpenCode failed to suggest a branch name"
  suggestion=$(extract_text_from_opencode_json "$raw_output") || die "Failed to parse the OpenCode branch suggestion"

  printf '%s\n' "$suggestion"
}

branch_name_is_valid() {
  local branch normalized_branch
  branch=$1
  [ -n "$branch" ] || return 1
  normalized_branch=$(git check-ref-format --branch "$branch" 2>/dev/null) || return 1
  [ "$normalized_branch" = "$branch" ]
}

confirm_branch_name() {
  local branch response
  branch=$1

  while :; do
    IFS= read -e -r -p "Branch name [$branch]: " response || die "Cancelled wt new"
    if [ -n "$response" ]; then
      branch=$response
    fi
    if branch_name_is_valid "$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
    warn "Invalid Git branch name: $branch"
  done
}

prompt_for_new_worktree_opencode_autostart() {
  local response

  while :; do
    printf 'Launch opencode with this prompt? (y/n) ' >&2
    IFS= read -e -r response || die "Cancelled wt new"
    case "$response" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *) warn "Please answer y or n" ;;
    esac
  done
}

launch_opencode_in_worktree() {
  local target_root goal
  local -a command
  target_root=$1
  goal=$2

  command=(opencode "$target_root" --agent "$WT_NEW_WORKTREE_AGENT" --prompt "$goal")
  if ! "${command[@]}" <&0 >&2 2>&2; then
    warn "opencode launch failed in: $target_root"
  fi
}

resolve_new_worktree_request() {
  local repo_root goal suggestion branch
  repo_root=$1

  goal=$(prompt_for_new_worktree_goal)
  suggestion=$(suggest_branch_name_with_opencode "$repo_root" "$goal")
  branch=$(confirm_branch_name "$suggestion")

  WT_NEW_WORKTREE_GOAL=$goal
  WT_NEW_WORKTREE_BRANCH=$branch
  WT_NEW_WORKTREE_AUTOSTART=0
  if prompt_for_new_worktree_opencode_autostart; then
    WT_NEW_WORKTREE_AUTOSTART=1
  fi
}

create_worktree_for_branch() {
  local branch repo_root worktree_root handle target_path env_copied package_manager i
  branch=$1

  repo_root=$(get_main_repo_root)
  worktree_root=$(get_worktree_root)
  handle=$(normalize_handle "$branch")
  target_path="$worktree_root/$handle"

  mkdir -p "$worktree_root"
  [ ! -e "$target_path" ] || die "Target path already exists: $target_path"

  ensure_unique_handle "$handle"
  list_worktrees
  i=0
  while [ $i -lt $WT_COUNT ]; do
    if [ "${WT_BRANCHES[$i]}" = "$branch" ]; then
      die "Branch is already checked out in: ${WT_PATHS[$i]}"
    fi
    i=$((i + 1))
  done

  if branch_exists_locally "$repo_root" "$branch"; then
    git -C "$repo_root" worktree add "$target_path" "$branch"
  else
    git -C "$repo_root" worktree add -b "$branch" "$target_path" HEAD
  fi

  env_copied=$(copy_env_candidates_from_notes "$repo_root" "$target_path")
  if inspect_portless_dev_script "$target_path" >/dev/null 2>&1; then
    initialize_worktree_debug_config "$target_path"
  else
    warn "Skipping wt init: package.json scripts.dev is not a supported portless command"
  fi
  package_manager=$(detect_package_manager "$target_path")

  if [ -n "$package_manager" ]; then
    run_install_for_worktree "$target_path" "$package_manager"
  else
    warn "Skipping dependency installation: no supported lockfile or packageManager hint found"
  fi

  note "repo_root: $repo_root"
  note "worktree_path: $target_path"
  note "branch: $branch"
  note "handle: $handle"
  note "env_files_copied: $env_copied"
  if [ -n "$package_manager" ]; then
    note "package_manager: $package_manager"
  else
    note "package_manager: skipped"
  fi
  note "next: cd \"$(printf '%s' "$target_path")\""
  note "next: wt open $branch"
  note "portless: if this repo uses portless, linked worktrees should get distinct local URLs when you start the app yourself"
}

