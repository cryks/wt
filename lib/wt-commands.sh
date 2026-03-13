cmd_open() {
  print_worktree_target_path "$@"
}

cmd_cd() {
  [ $# -eq 1 ] || die "Usage: wt cd <branch-or-handle>"
  print_worktree_target_path "$1"
}

cmd_ls() {
  local i width_type width_branch width_handle width_state
  [ $# -eq 0 ] || die "Usage: wt ls"
  require_git_repo
  list_worktrees

  width_type=4
  width_branch=6
  width_handle=6
  width_state=5

  i=0
  while [ $i -lt $WT_COUNT ]; do
    [ ${#WT_TYPES[$i]} -gt $width_type ] && width_type=${#WT_TYPES[$i]}
    [ ${#WT_BRANCHES[$i]} -gt $width_branch ] && width_branch=${#WT_BRANCHES[$i]}
    [ ${#WT_HANDLES[$i]} -gt $width_handle ] && width_handle=${#WT_HANDLES[$i]}
    [ ${#WT_STATES[$i]} -gt $width_state ] && width_state=${#WT_STATES[$i]}
    i=$((i + 1))
  done

  format_table_row "$width_branch" "$width_handle" "$width_type" "$width_state" "BRANCH" "HANDLE" "TYPE" "STATE" "PATH"
  i=0
  while [ $i -lt $WT_COUNT ]; do
    format_table_row "$width_branch" "$width_handle" "$width_type" "$width_state" \
      "${WT_BRANCHES[$i]}" "${WT_HANDLES[$i]}" "${WT_TYPES[$i]}" "${WT_STATES[$i]}" "${WT_PATHS[$i]}"
    i=$((i + 1))
  done
}

cmd_init() {
  local target_root
  [ $# -eq 0 ] || die "Usage: wt init"
  target_root=$(resolve_target_root_or_current)
  initialize_worktree_debug_config "$target_root"
}

cmd_b() {
  local target_root url
  [ $# -le 1 ] || die "Usage: wt b [branch-or-handle]"
  target_root=$(resolve_target_root_or_current "$@")
  url=$(derive_portless_url "$target_root")
  launch_debug_browser_for_url "$url"
  note "debug_url: $url"
}


cmd_new() {
  local branch current_repo_root target_path
  [ $# -le 1 ] || die "Usage: wt new [branch]"
  require_git_repo

  WT_NEW_WORKTREE_BRANCH=""
  WT_NEW_WORKTREE_GOAL=""
  WT_NEW_WORKTREE_AUTOSTART=0

  if [ $# -eq 0 ]; then
    require_interactive_terminal
    current_repo_root=$(get_repo_root)
    resolve_new_worktree_request "$current_repo_root"
    branch=$WT_NEW_WORKTREE_BRANCH
  else
    branch=$1
  fi

  create_worktree_for_branch "$branch"

  if [ $WT_NEW_WORKTREE_AUTOSTART -eq 1 ]; then
    target_path="$(get_worktree_root)/$(normalize_handle "$branch")"
    launch_opencode_in_worktree "$target_path" "$WT_NEW_WORKTREE_GOAL"
  fi
}

cmd_rm() {
  local force target index repo_root main_repo_root target_path target_state target_type target_branch cmd branch_cmd i
  force=0
  target=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --force)
        force=1
        ;;
      --help|-h)
        printf '%s\n' "Usage: wt rm [--force] [branch-or-handle]"
        return 0
        ;;
      *)
        if [ -n "$target" ]; then
          die "Usage: wt rm [--force] [branch-or-handle]"
        fi
        target=$1
        ;;
    esac
    shift
  done

  require_git_repo
  repo_root=$(get_repo_root)
  main_repo_root=$(get_main_repo_root)

  if [ -n "$target" ]; then
    resolve_worktree_target "$target"
    index=$WT_TARGET_INDEX
  else
    list_worktrees
    index=""
    i=0
    while [ $i -lt $WT_COUNT ]; do
      if [ "${WT_PATHS[$i]}" = "$repo_root" ]; then
        index=$i
        break
      fi
      i=$((i + 1))
    done
    [ -n "$index" ] || die "Unable to resolve the current worktree"
  fi

  target_path=${WT_PATHS[$index]}
  target_state=${WT_STATES[$index]}
  target_type=${WT_TYPES[$index]}
  target_branch=${WT_BRANCHES[$index]}

  [ "$target_type" != "primary" ] || die "Refusing to remove the primary worktree"
  if [ -n "$target" ]; then
    current_working_tree_is_inside "$target_path" && die "Refusing to remove a worktree from inside that worktree: $target_path"
  fi
  case ",$target_state," in
    *,locked,*) die "Refusing to remove a locked worktree in v1: $target_path" ;;
  esac
  case ",$target_state," in
    *,dirty,*)
      if [ $force -ne 1 ]; then
        die "Refusing to remove a dirty worktree without --force: $target_path"
      fi
      ;;
  esac

  cmd=(git -C "$main_repo_root" worktree remove)
  if [ $force -eq 1 ]; then
    cmd+=(--force)
  fi
  cmd+=("$target_path")
  "${cmd[@]}"

  note "removed_worktree: $target_path"

  if [ "$target_branch" = "HEAD" ]; then
    note "branch_retained: $target_branch"
    return 0
  fi

  branch_cmd=(git -C "$main_repo_root" branch)
  if [ $force -eq 1 ]; then
    branch_cmd+=(-D)
  else
    branch_cmd+=(-d)
  fi
  branch_cmd+=("$target_branch")

  if "${branch_cmd[@]}"; then
    note "removed_branch: $target_branch"
    return 0
  fi

  warn "branch_retained: $target_branch"
  if [ $force -eq 1 ]; then
    die "Removed worktree but failed to delete branch with git branch -D: $target_branch"
  fi
  die "Removed worktree but failed to delete branch with git branch -d: $target_branch"
}

merge_head_exists() {
  local worktree_root git_dir
  worktree_root=$1
  git_dir=$(git -C "$worktree_root" rev-parse --path-format=absolute --git-dir 2>/dev/null \
    || git -C "$worktree_root" rev-parse --git-dir)
  [ -f "$git_dir/MERGE_HEAD" ]
}

merge_branch_into_current() {
  local target_root current_branch incoming_branch action_label action_title merge_output
  target_root=$1
  current_branch=$2
  incoming_branch=$3
  action_label=$4
  action_title=$5

  if merge_output=$(git -C "$target_root" merge "$incoming_branch" 2>&1); then
    note "$action_label: resolved without conflicts"
    return 0
  fi

  if ! merge_head_exists "$target_root"; then
    [ -n "$merge_output" ] || merge_output="$action_title failed for an unexpected reason"
    die "$merge_output"
  fi

  note "$action_label: conflicts detected, launching AI resolver"
  if ! command -v opencode >/dev/null 2>&1; then
    warn "$action_label: opencode is required for AI conflict resolution, aborting"
    git -C "$target_root" merge --abort >/dev/null 2>&1 || true
    die "$action_title aborted: missing required command: opencode"
  fi

  opencode "$target_root" --agent "Maat" --model "$WT_MERGE_MODEL" \
    --prompt "Merge conflicts need to be resolved. Branch '$current_branch' is merging '$incoming_branch'. Examine the conflicts, resolve them, stage the files, and run 'git merge --continue --no-edit'." \
    || true

  if merge_head_exists "$target_root"; then
    warn "$action_label: conflicts not fully resolved, aborting"
    git -C "$target_root" merge --abort >/dev/null 2>&1 || true
    die "$action_title aborted: conflicts were not fully resolved"
  fi

  note "$action_label: conflicts resolved by AI"
}

resolve_current_worktree_index() {
  local repo_root i index
  repo_root=$(get_repo_root)

  list_worktrees
  index=""
  i=0
  while [ $i -lt $WT_COUNT ]; do
    if [ "${WT_PATHS[$i]}" = "$repo_root" ]; then
      index=$i
      break
    fi
    i=$((i + 1))
  done

  [ -n "$index" ] || die "Unable to resolve the current worktree"
  WT_TARGET_INDEX=$index
}

merge_cleanup() {
  local main_root feature_root feature_branch
  main_root=$1
  feature_root=$2
  feature_branch=$3

  git -C "$main_root" worktree remove "$feature_root" \
    || die "Failed to remove worktree: $feature_root"
  note "removed_worktree: $feature_root"

  if git -C "$main_root" branch -d "$feature_branch" >/dev/null 2>&1; then
    note "removed_branch: $feature_branch"
  else
    warn "branch_retained: $feature_branch"
  fi
}

cmd_merge() {
  local main_root primary_branch feature_root feature_branch unique_commits index

  [ $# -eq 0 ] || die "Usage: wt merge"
  require_git_repo

  main_root=$(get_main_repo_root)
  primary_branch=$(get_primary_branch "$main_root")
  resolve_current_worktree_index
  index=$WT_TARGET_INDEX

  feature_root="${WT_PATHS[$index]}"
  feature_branch="${WT_BRANCHES[$index]}"

  [ "${WT_TYPES[$index]}" != "primary" ] || die "Cannot merge: already on the primary worktree"
  [ "$feature_branch" != "HEAD" ] || die "Cannot merge: current worktree has a detached HEAD"
  [ "$(git_dirty_state "$feature_root")" = "clean" ] || die "Cannot merge: worktree has uncommitted changes"

  unique_commits=$(git -C "$feature_root" log "$primary_branch..$feature_branch" --oneline 2>/dev/null || true)
  [ -n "$unique_commits" ] || die "Cannot merge: no commits ahead of $primary_branch"

  if git -C "$main_root" merge --ff-only "$feature_branch" >/dev/null 2>&1; then
    note "merge: fast-forward"
  else
    merge_branch_into_current "$feature_root" "$feature_branch" "$primary_branch" "merge" "Merge"

    git -C "$main_root" merge --ff-only "$feature_branch" >/dev/null 2>&1 \
      || die "Unexpected: fast-forward failed after reverse merge"
    note "merge: primary updated"
  fi

  merge_cleanup "$main_root" "$feature_root" "$feature_branch"
}

cmd_sync() {
  local main_root primary_branch feature_root feature_branch incoming_commits index

  [ $# -eq 0 ] || die "Usage: wt sync"
  require_git_repo

  main_root=$(get_main_repo_root)
  primary_branch=$(get_primary_branch "$main_root")
  resolve_current_worktree_index
  index=$WT_TARGET_INDEX

  feature_root="${WT_PATHS[$index]}"
  feature_branch="${WT_BRANCHES[$index]}"

  [ "${WT_TYPES[$index]}" != "primary" ] || die "Cannot sync: already on the primary worktree"
  [ "$feature_branch" != "HEAD" ] || die "Cannot sync: current worktree has a detached HEAD"
  [ "$(git_dirty_state "$feature_root")" = "clean" ] || die "Cannot sync: worktree has uncommitted changes"

  incoming_commits=$(git -C "$feature_root" log "$feature_branch..$primary_branch" --oneline 2>/dev/null || true)
  [ -n "$incoming_commits" ] || die "Cannot sync: no commits ahead on $primary_branch"

  if git -C "$feature_root" merge --ff-only "$primary_branch" >/dev/null 2>&1; then
    note "sync: fast-forward"
    return 0
  fi

  merge_branch_into_current "$feature_root" "$feature_branch" "$primary_branch" "sync" "Sync"
}
