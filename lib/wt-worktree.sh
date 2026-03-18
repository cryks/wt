git_tracked_directories() {
  local repo_root
  repo_root=$1

  git -C "$repo_root" ls-files -z | python3 -c '
import os
import sys

data = sys.stdin.buffer.read().split(b"\0")
seen = set()
ordered = []

def add(path: str) -> None:
    if path not in seen:
        seen.add(path)
        ordered.append(path)

add(".")

for raw_path in data:
    if not raw_path:
        continue
    path = raw_path.decode("utf-8")
    directory = os.path.dirname(path)
    while True:
        add(directory or ".")
        if not directory:
            break
        parent = os.path.dirname(directory)
        if parent == directory:
            break
        directory = parent

for path in ordered:
    sys.stdout.buffer.write(path.encode("utf-8") + b"\0")
'
}

WT_LAST_COPIED_COUNT=0
WT_LAST_COPIED_ITEMS=()

copy_env_candidates_from_notes() {
  local source_root target_root copied candidate source_path target_path relative_dir relative_path scan_dir
  source_root=$1
  target_root=$2
  copied=0
  WT_LAST_COPIED_COUNT=0
  WT_LAST_COPIED_ITEMS=()

  for candidate in "${ENV_CANDIDATES[@]}"; do
    source_path="$source_root/$candidate"
    target_path="$target_root/$candidate"
    if [ -e "$source_path" ] && [ ! -e "$target_path" ]; then
      cp -R "$source_path" "$target_path"
      copied=$((copied + 1))
      WT_LAST_COPIED_ITEMS+=("$candidate")
    fi
  done

  while IFS= read -r -d '' relative_dir; do
    scan_dir="$source_root"
    if [ "$relative_dir" != "." ]; then
      scan_dir="$source_root/$relative_dir"
    fi

    for source_path in "$scan_dir"/.* "$scan_dir"/*; do
      [ -e "$source_path" ] || continue
      candidate=$(basename "$source_path")
      case "$candidate" in
        .|..) continue ;;
        *.local|*.local.*)
          relative_path=$candidate
          if [ "$relative_dir" != "." ]; then
            relative_path="$relative_dir/$candidate"
          fi
          target_path="$target_root/$relative_path"
          if [ ! -e "$target_path" ]; then
            cp -R "$source_path" "$target_path"
            copied=$((copied + 1))
            WT_LAST_COPIED_ITEMS+=("$relative_path")
          fi
          ;;
      esac
    done
  done < <(git_tracked_directories "$source_root")

  WT_LAST_COPIED_COUNT=$copied
  printf '%s\n' "$copied"
}

run_install_for_worktree() {
  local target_root package_manager
  target_root=$1
  package_manager=$2

  [ -n "$package_manager" ] || return 0
  command -v "$package_manager" >/dev/null 2>&1 || die "Detected package manager '$package_manager' but it is not available on PATH. The worktree was created at: $target_root"

  case "$package_manager" in
    pnpm)
      note ""
      note "Installing dependencies with: pnpm install --prefer-offline"
      note ""
      run_command_with_dimmed_output bash -lc 'cd "$1" && pnpm install --prefer-offline' bash "$target_root"
      ;;
    npm)
      note ""
      note "Installing dependencies with: npm install --prefer-offline"
      note ""
      run_command_with_dimmed_output bash -lc 'cd "$1" && npm install --prefer-offline' bash "$target_root"
      ;;
    bun)
      note ""
      note "Installing dependencies with: bun install"
      note ""
      run_command_with_dimmed_output bash -lc 'cd "$1" && bun install' bash "$target_root"
      ;;
    *)
      die "Unsupported package manager: $package_manager"
      ;;
  esac
}

current_working_tree_is_inside() {
  local target abs_pwd
  target=$1
  abs_pwd=$(pwd -P)
  case "$abs_pwd" in
    "$target"|"$target"/*) return 0 ;;
    *) return 1 ;;
  esac
}

git_dirty_state() {
  local path status_output
  path=$1
  if [ ! -d "$path" ]; then
    printf '%s\n' "clean"
    return 0
  fi
  status_output=$(git -C "$path" status --porcelain --untracked-files=normal 2>/dev/null || true)
  if [ -n "$status_output" ]; then
    printf '%s\n' "dirty"
  else
    printf '%s\n' "clean"
  fi
}

WT_COUNT=0
WT_PATHS=()
WT_BRANCHES=()
WT_TYPES=()
WT_HANDLES=()
WT_STATES=()
WT_TARGET_INDEX=""

append_worktree_record() {
  local repo_root worktree_root path branch type handle state dirty annotation
  repo_root=$1
  worktree_root=$2
  path=$3
  branch=$4
  annotation=$5

  if [ "$path" = "$repo_root" ]; then
    type="primary"
    handle="-"
  else
    type="linked"
    case "$path" in
      "$worktree_root"/*) handle=$(basename "$path") ;;
      *) handle=$(basename "$path") ;;
    esac
  fi

  dirty=$(git_dirty_state "$path")
  state="$dirty"

  if [ ! -d "$path" ]; then
    state="$state,missing"
  fi
  case ",$annotation," in
    *,locked,*) state="$state,locked" ;;
  esac
  case ",$annotation," in
    *,prunable,*) state="$state,prunable" ;;
  esac

  WT_PATHS[$WT_COUNT]="$path"
  WT_BRANCHES[$WT_COUNT]="$branch"
  WT_TYPES[$WT_COUNT]="$type"
  WT_HANDLES[$WT_COUNT]="$handle"
  WT_STATES[$WT_COUNT]="$state"
  WT_COUNT=$((WT_COUNT + 1))
}

worktree_state_has() {
  local state flag
  state=$1
  flag=$2

  case ",$state," in
    *,$flag,*) return 0 ;;
    *) return 1 ;;
  esac
}

list_worktrees() {
  local repo_root worktree_root entry path branch annotation token key value
  repo_root=$(get_main_repo_root)
  worktree_root=$(get_worktree_root)

  WT_COUNT=0
  WT_PATHS=()
  WT_BRANCHES=()
  WT_TYPES=()
  WT_HANDLES=()
  WT_STATES=()

  path=""
  branch="HEAD"
  annotation=""

  while IFS= read -r -d '' entry; do
    if [ -z "$entry" ]; then
      if [ -n "$path" ]; then
        append_worktree_record "$repo_root" "$worktree_root" "$path" "$branch" "$annotation"
      fi
      path=""
      branch="HEAD"
      annotation=""
      continue
    fi

    token=${entry%% *}
    if [ "$token" = "$entry" ]; then
      key=$entry
      value=""
    else
      key=$token
      value=${entry#* }
    fi

    case "$key" in
      worktree) path=$value ;;
      branch) branch=${value#refs/heads/} ;;
      detached) branch="HEAD" ;;
      locked)
        if [ -n "$annotation" ]; then
          annotation="$annotation,locked"
        else
          annotation="locked"
        fi
        ;;
      prunable)
        if [ -n "$annotation" ]; then
          annotation="$annotation,prunable"
        else
          annotation="prunable"
        fi
        ;;
    esac
  done < <(git -C "$repo_root" worktree list --porcelain -z)

  if [ -n "$path" ]; then
    append_worktree_record "$repo_root" "$worktree_root" "$path" "$branch" "$annotation"
  fi
}

resolve_worktree_index_by_path() {
  local target_path i
  target_path=$1

  list_worktrees
  WT_TARGET_INDEX=""

  i=0
  while [ $i -lt $WT_COUNT ]; do
    if [ "${WT_PATHS[$i]}" = "$target_path" ]; then
      WT_TARGET_INDEX=$i
      return 0
    fi
    i=$((i + 1))
  done

  die "Unable to resolve the requested worktree path: $target_path"
}

ensure_unique_handle() {
  local requested_handle i
  requested_handle=$1
  list_worktrees
  i=0
  while [ $i -lt $WT_COUNT ]; do
    if [ "${WT_TYPES[$i]}" = "linked" ] && [ "${WT_HANDLES[$i]}" = "$requested_handle" ]; then
      die "Handle already exists: $requested_handle (${WT_PATHS[$i]})"
    fi
    i=$((i + 1))
  done
}

resolve_worktree_target() {
  local query handle_match_index branch_match_index i
  query=${1-}
  [ -n "$query" ] || die "A branch or handle is required"
  list_worktrees

  WT_TARGET_INDEX=""

  handle_match_index=""
  branch_match_index=""
  i=0
  while [ $i -lt $WT_COUNT ]; do
    if [ "${WT_TYPES[$i]}" = "linked" ] && [ "${WT_HANDLES[$i]}" = "$query" ] && [ -z "$handle_match_index" ]; then
      handle_match_index=$i
    fi
    if [ "${WT_BRANCHES[$i]}" = "$query" ] && [ -z "$branch_match_index" ]; then
      branch_match_index=$i
    fi
    i=$((i + 1))
  done

  if [ -n "$handle_match_index" ] && [ -n "$branch_match_index" ] && [ "$handle_match_index" != "$branch_match_index" ]; then
    die "Ambiguous target '$query': handle -> ${WT_PATHS[$handle_match_index]}, branch -> ${WT_PATHS[$branch_match_index]}"
  fi
  if [ -n "$handle_match_index" ]; then
    WT_TARGET_INDEX=$handle_match_index
    return 0
  fi
  if [ -n "$branch_match_index" ]; then
    WT_TARGET_INDEX=$branch_match_index
    return 0
  fi

  die "No worktree matched branch or handle: $query"
}

format_table_row() {
  local c1w c2w c3w c4w c1 c2 c3 c4 c5
  c1w=$1
  c2w=$2
  c3w=$3
  c4w=$4
  c1=$5
  c2=$6
  c3=$7
  c4=$8
  c5=$9
  printf "%-${c1w}s  %-${c2w}s  %-${c3w}s  %-${c4w}s  %s\n" "$c1" "$c2" "$c3" "$c4" "$c5"
}

print_worktree_target_path() {
  local target index
  [ $# -eq 1 ] || die "Usage: wt open <branch-or-handle>"
  target=$1
  require_git_repo
  resolve_worktree_target "$target"
  index=$WT_TARGET_INDEX
  printf '%s\n' "${WT_PATHS[$index]}"
}
