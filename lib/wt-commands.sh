WT_PRIMARY_COMPARE_REF=""
WT_PRIMARY_COMPARE_LABEL=""
WT_TARGET_COMPARE_REF=""
WT_TARGET_COMPARE_LABEL=""
WT_RELATION_BEHIND=0
WT_RELATION_AHEAD=0

resolve_primary_compare_ref() {
  local main_root branch head short_head
  main_root=$1

  branch=$(git -C "$main_root" branch --show-current 2>/dev/null || true)
  if [ -n "$branch" ]; then
    WT_PRIMARY_COMPARE_REF=$branch
    WT_PRIMARY_COMPARE_LABEL=$branch
    return 0
  fi

  head=$(git -C "$main_root" rev-parse --verify HEAD) || die "Unable to resolve the current primary HEAD from: $main_root"
  short_head=$(git -C "$main_root" rev-parse --short "$head")
  WT_PRIMARY_COMPARE_REF=$head
  WT_PRIMARY_COMPARE_LABEL="HEAD ($short_head)"
}

resolve_worktree_compare_ref() {
  local index target_path target_branch head short_head
  index=$1
  target_path=${WT_PATHS[$index]}
  target_branch=${WT_BRANCHES[$index]}

  if [ "$target_branch" != "HEAD" ]; then
    WT_TARGET_COMPARE_REF=$target_branch
    WT_TARGET_COMPARE_LABEL=$target_branch
    return 0
  fi

  if [ -d "$target_path" ]; then
    head=$(git -C "$target_path" rev-parse --verify HEAD) || die "Unable to resolve HEAD for worktree: $target_path"
    short_head=$(git -C "$target_path" rev-parse --short "$head")
    WT_TARGET_COMPARE_REF=$head
    WT_TARGET_COMPARE_LABEL="HEAD ($short_head)"
    return 0
  fi

  WT_TARGET_COMPARE_REF=""
  WT_TARGET_COMPARE_LABEL="HEAD (missing)"
}

compute_branch_relation() {
  local repo_root compare_ref target_ref
  repo_root=$1
  compare_ref=$2
  target_ref=$3

  set -- $(git -C "$repo_root" rev-list --left-right --count "$compare_ref...$target_ref")
  WT_RELATION_BEHIND=${1:-0}
  WT_RELATION_AHEAD=${2:-0}
}

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

cmd_status() {
  local target_root index main_root i linked_count stale_count sync_status merge_status

  [ $# -le 1 ] || die "Usage: wt status [branch-or-handle]"
  require_git_repo

  target_root=$(resolve_target_root_or_current "$@")
  resolve_worktree_index_by_path "$target_root"
  index=$WT_TARGET_INDEX
  main_root=$(get_main_repo_root)

  note_section "Status"
  note_detail "worktree_path" "${WT_PATHS[$index]}"
  note_detail "type" "${WT_TYPES[$index]}"
  note_detail "branch" "${WT_BRANCHES[$index]}"
  if [ "${WT_HANDLES[$index]}" != "-" ]; then
    note_detail "handle" "${WT_HANDLES[$index]}"
  fi
  note_detail "state" "${WT_STATES[$index]}"

  if [ "${WT_TYPES[$index]}" = "primary" ]; then
    linked_count=0
    stale_count=0
    i=0
    while [ $i -lt $WT_COUNT ]; do
      if [ "${WT_TYPES[$i]}" = "linked" ]; then
        linked_count=$((linked_count + 1))
        if worktree_state_has "${WT_STATES[$i]}" "missing" || worktree_state_has "${WT_STATES[$i]}" "prunable"; then
          stale_count=$((stale_count + 1))
        fi
      fi
      i=$((i + 1))
    done
    note_detail "linked_worktrees" "$linked_count"
    note_detail "stale_worktrees" "$stale_count"
    return 0
  fi

  resolve_primary_compare_ref "$main_root"
  resolve_worktree_compare_ref "$index"
  note_detail "primary_ref" "$WT_PRIMARY_COMPARE_LABEL"

  if [ -z "$WT_TARGET_COMPARE_REF" ]; then
    note_detail "ahead_of_primary" "unavailable"
    note_detail "behind_primary" "unavailable"
    note_detail "sync_status" "blocked-missing-detached-head"
    note_detail "merge_status" "blocked-missing-detached-head"
    return 0
  fi

  compute_branch_relation "$main_root" "$WT_PRIMARY_COMPARE_REF" "$WT_TARGET_COMPARE_REF"
  note_detail "ahead_of_primary" "$WT_RELATION_AHEAD"
  note_detail "behind_primary" "$WT_RELATION_BEHIND"

  if [ "${WT_BRANCHES[$index]}" = "HEAD" ]; then
    sync_status="blocked-detached-head"
    merge_status="blocked-detached-head"
  elif worktree_state_has "${WT_STATES[$index]}" "dirty"; then
    sync_status="blocked-dirty"
    merge_status="blocked-dirty"
  else
    if [ "$WT_RELATION_BEHIND" -eq 0 ]; then
      sync_status="up-to-date"
    elif [ "$WT_RELATION_AHEAD" -eq 0 ]; then
      sync_status="fast-forward"
    else
      sync_status="merge-required"
    fi

    if [ "$WT_RELATION_AHEAD" -eq 0 ]; then
      merge_status="no-commits-ahead"
    elif [ "$WT_RELATION_BEHIND" -eq 0 ]; then
      merge_status="fast-forward"
    else
      merge_status="reverse-merge-required"
    fi
  fi

  note_detail "sync_status" "$sync_status"
  note_detail "merge_status" "$merge_status"
}

cmd_diff() {
  local target_root index main_root commit_summary line

  [ $# -le 1 ] || die "Usage: wt diff [branch-or-handle]"
  require_git_repo

  target_root=$(resolve_target_root_or_current "$@")
  resolve_worktree_index_by_path "$target_root"
  index=$WT_TARGET_INDEX
  [ "${WT_TYPES[$index]}" != "primary" ] || die "Cannot diff: already on the primary worktree; pass a branch or handle"
  [ "$(git_dirty_state "$target_root")" = "clean" ] || die "Cannot diff: worktree has uncommitted changes"

  main_root=$(get_main_repo_root)
  resolve_primary_compare_ref "$main_root"
  resolve_worktree_compare_ref "$index"
  [ -n "$WT_TARGET_COMPARE_REF" ] || die "Cannot diff: a missing detached worktree cannot be compared"
  compute_branch_relation "$main_root" "$WT_PRIMARY_COMPARE_REF" "$WT_TARGET_COMPARE_REF"

  note_section "Diff"
  note_detail "worktree_path" "${WT_PATHS[$index]}"
  note_detail "branch" "${WT_BRANCHES[$index]}"
  if [ "${WT_HANDLES[$index]}" != "-" ]; then
    note_detail "handle" "${WT_HANDLES[$index]}"
  fi
  note_detail "state" "${WT_STATES[$index]}"
  note_detail "primary_ref" "$WT_PRIMARY_COMPARE_LABEL"
  note_detail "target_ref" "$WT_TARGET_COMPARE_LABEL"
  note_detail "ahead_of_primary" "$WT_RELATION_AHEAD"
  note_detail "behind_primary" "$WT_RELATION_BEHIND"

  if git -C "$main_root" diff --quiet "$WT_PRIMARY_COMPARE_REF...$WT_TARGET_COMPARE_REF" --; then
    note_detail "diff" "no changes against primary"
    return 0
  fi

  commit_summary=$(git -C "$main_root" log --oneline "$WT_PRIMARY_COMPARE_REF..$WT_TARGET_COMPARE_REF" 2>/dev/null || true)
  if [ -n "$commit_summary" ]; then
    note_section "Commits"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      note_status "$line"
    done <<EOF
$commit_summary
EOF
  fi

  note_section "Patch"
  run_command_with_dimmed_output git -C "$main_root" --no-pager diff "$WT_PRIMARY_COMPARE_REF...$WT_TARGET_COMPARE_REF"
}

cmd_prune() {
  local dry_run main_root i state
  local -a stale_paths stale_states locked_paths locked_states cmd

  dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)
        dry_run=1
        ;;
      --help|-h)
        printf '%s\n' "Usage: wt prune [--dry-run]"
        return 0
        ;;
      *)
        die "Usage: wt prune [--dry-run]"
        ;;
    esac
    shift
  done

  require_git_repo
  main_root=$(get_main_repo_root)
  list_worktrees

  i=0
  while [ $i -lt $WT_COUNT ]; do
    state=${WT_STATES[$i]}
    if [ "${WT_TYPES[$i]}" = "linked" ] && { worktree_state_has "$state" "missing" || worktree_state_has "$state" "prunable"; }; then
      if worktree_state_has "$state" "locked"; then
        locked_paths+=("${WT_PATHS[$i]}")
        locked_states+=("$state")
      else
        stale_paths+=("${WT_PATHS[$i]}")
        stale_states+=("$state")
      fi
    fi
    i=$((i + 1))
  done

  note_section "Prune"
  if [ $dry_run -eq 1 ]; then
    note_detail "dry_run" "true"
  fi

  if [ ${#stale_paths[@]} -eq 0 ]; then
    note_detail "prune" "nothing to do"
    if [ ${#locked_paths[@]} -gt 0 ]; then
      note_detail "skipped_locked" "${#locked_paths[@]}"
      i=0
      while [ $i -lt ${#locked_paths[@]} ]; do
        note_list_item "locked: ${locked_paths[$i]} (${locked_states[$i]})"
        i=$((i + 1))
      done
    fi
    return 0
  fi

  note_detail "stale_worktrees" "${#stale_paths[@]}"
  i=0
  while [ $i -lt ${#stale_paths[@]} ]; do
    note_list_item "stale: ${stale_paths[$i]} (${stale_states[$i]})"
    i=$((i + 1))
  done

  if [ ${#locked_paths[@]} -gt 0 ]; then
    note_detail "skipped_locked" "${#locked_paths[@]}"
    i=0
    while [ $i -lt ${#locked_paths[@]} ]; do
      note_list_item "locked: ${locked_paths[$i]} (${locked_states[$i]})"
      i=$((i + 1))
    done
  fi

  cmd=(git -C "$main_root" worktree prune --expire now --verbose)
  if [ $dry_run -eq 1 ]; then
    cmd+=(--dry-run)
  fi
  run_command_with_dimmed_output "${cmd[@]}"

  if [ $dry_run -eq 1 ]; then
    return 0
  fi

  note_section "Pruned"
  note_detail "pruned_worktrees" "${#stale_paths[@]}"
  i=0
  while [ $i -lt ${#stale_paths[@]} ]; do
    note_list_item "pruned: ${stale_paths[$i]}"
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
  note_section "Browser"
  launch_debug_browser_for_url "$url"
  note_detail "debug_url" "$url"
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

  note_section "Remove"
  note_detail "worktree_path" "$target_path"
  if [ "$target_branch" != "HEAD" ]; then
    note_detail "branch" "$target_branch"
  fi
  if [ $force -eq 1 ]; then
    note_detail "force" "true"
  fi

  cmd=(git -C "$main_repo_root" worktree remove)
  if [ $force -eq 1 ]; then
    cmd+=(--force)
  fi
  cmd+=("$target_path")
  run_command_with_dimmed_output "${cmd[@]}"

  note_section "Removed"
  note_detail "removed_worktree" "$target_path"

  if [ "$target_branch" = "HEAD" ]; then
    note_detail "branch_retained" "$target_branch"
    return 0
  fi

  branch_cmd=(git -C "$main_repo_root" branch)
  if [ $force -eq 1 ]; then
    branch_cmd+=(-D)
  else
    branch_cmd+=(-d)
  fi
  branch_cmd+=("$target_branch")

  if run_command_with_dimmed_output "${branch_cmd[@]}"; then
    note_detail "removed_branch" "$target_branch"
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
    note_detail "$action_label" "resolved without conflicts"
    return 0
  fi

  if ! merge_head_exists "$target_root"; then
    [ -n "$merge_output" ] || merge_output="$action_title failed for an unexpected reason"
    die "$merge_output"
  fi

  note_detail "$action_label" "conflicts detected, launching AI resolver"
  if ! command -v opencode >/dev/null 2>&1; then
    warn "$action_label: opencode is required for AI conflict resolution, aborting"
    git -C "$target_root" merge --abort >/dev/null 2>&1 || true
    die "$action_title aborted: missing required command: opencode"
  fi

  opencode "$target_root" --agent "Maat" --model "$WT_MERGE_MODEL" \
    --prompt "Merge conflicts need to be resolved. Branch '$current_branch' is merging '$incoming_branch'. Prefer the current branch/worktree side as the default source of truth because it represents the worktree-local branch state the user is actively editing. Only take incoming-branch changes when they combine cleanly without undermining the current branch intent. If any conflict is ambiguous, use the question tool instead of guessing. Examine the conflicts, resolve them, stage the files, and run 'GIT_EDITOR=true git merge --continue'." \
    || true

  if merge_head_exists "$target_root"; then
    warn "$action_label: conflicts not fully resolved, aborting"
    git -C "$target_root" merge --abort >/dev/null 2>&1 || true
    die "$action_title aborted: conflicts were not fully resolved"
  fi

  note_detail "$action_label" "conflicts resolved by AI"
}

resolve_current_worktree_index() {
  resolve_worktree_index_by_path "$(get_repo_root)"
}

merge_cleanup() {
  local main_root feature_root feature_branch
  main_root=$1
  feature_root=$2
  feature_branch=$3

  run_command_with_dimmed_output git -C "$main_root" worktree remove "$feature_root" \
    || die "Failed to remove worktree: $feature_root"
  note_section "Removed"
  note_detail "removed_worktree" "$feature_root"

  if run_command_with_dimmed_output git -C "$main_root" branch -d "$feature_branch"; then
    note_detail "removed_branch" "$feature_branch"
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

  note_section "Merge"
  note_detail "primary_branch" "$primary_branch"
  note_detail "feature_branch" "$feature_branch"

  unique_commits=$(git -C "$feature_root" log "$primary_branch..$feature_branch" --oneline 2>/dev/null || true)
  [ -n "$unique_commits" ] || die "Cannot merge: no commits ahead of $primary_branch"

  if git -C "$main_root" merge --ff-only "$feature_branch" >/dev/null 2>&1; then
    note_detail "merge" "fast-forward"
  else
    merge_branch_into_current "$feature_root" "$feature_branch" "$primary_branch" "merge" "Merge"

    git -C "$main_root" merge --ff-only "$feature_branch" >/dev/null 2>&1 \
      || die "Unexpected: fast-forward failed after reverse merge"
    note_detail "merge" "primary updated"
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

  note_section "Sync"
  note_detail "primary_branch" "$primary_branch"
  note_detail "feature_branch" "$feature_branch"

  incoming_commits=$(git -C "$feature_root" log "$feature_branch..$primary_branch" --oneline 2>/dev/null || true)
  [ -n "$incoming_commits" ] || die "Cannot sync: no commits ahead on $primary_branch"

  if git -C "$feature_root" merge --ff-only "$primary_branch" >/dev/null 2>&1; then
    note_detail "sync" "fast-forward"
    return 0
  fi

  merge_branch_into_current "$feature_root" "$feature_branch" "$primary_branch" "sync" "Sync"
}
