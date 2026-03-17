ENV_CANDIDATES=(".env")
WT_MANAGED_LAUNCH_NAME="wt: attach browser"
WT_DEBUG_PORT_DEFAULT="9222"
WT_BRANCH_NAME_MODEL="${WT_BRANCH_NAME_MODEL:-opencode-go/kimi-k2.5}"
WT_MERGE_MODEL="${WT_MERGE_MODEL:-opencode-go/glm-5}"
WT_NEW_WORKTREE_AGENT="Build"
WT_NEW_WORKTREE_BRANCH=""
WT_NEW_WORKTREE_GOAL=""
WT_NEW_WORKTREE_AUTOSTART=0

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

WT_STDOUT_STYLE_ENABLED=""

init_stdout_style() {
  if [ -n "$WT_STDOUT_STYLE_ENABLED" ]; then
    return 0
  fi

  if [ "${WT_FORCE_STDOUT_STYLE:-0}" = "1" ] && [ -z "${NO_COLOR-}" ]; then
    WT_STDOUT_STYLE_ENABLED=1
  elif [ -t 1 ] && [ -z "${NO_COLOR-}" ]; then
    WT_STDOUT_STYLE_ENABLED=1
  else
    WT_STDOUT_STYLE_ENABLED=0
  fi
}

stdout_supports_color() {
  init_stdout_style
  [ "$WT_STDOUT_STYLE_ENABLED" = "1" ]
}

style_line() {
  local code text
  code=$1
  text=$2

  if stdout_supports_color; then
    printf '\033[%sm%s\033[0m' "$code" "$text"
  else
    printf '%s' "$text"
  fi
}

note_section() {
  local prefix
  init_stdout_style
  printf '\n'
  style_line "1;36" "==>"
  printf ' %s\n' "$1"
}

note_detail() {
  init_stdout_style
  if stdout_supports_color; then
    printf '  '
    style_line "0" "$1: $2"
    printf '\n'
  else
    printf '  %s: %s\n' "$1" "$2"
  fi
}

note_list_item() {
  init_stdout_style
  if stdout_supports_color; then
    printf '    '
    style_line "2" "- $1"
    printf '\n'
  else
    printf '    - %s\n' "$1"
  fi
}

note_status() {
  init_stdout_style
  if stdout_supports_color; then
    printf '  '
    style_line "0" "-> $1"
    printf '\n'
  else
    printf '  -> %s\n' "$1"
  fi
}

run_command_with_dimmed_output() {
  if stdout_supports_color; then
    "$@" 2>&1 | while IFS= read -r line; do
      style_line "2" "$line"
      printf '\n'
    done
    return ${PIPESTATUS[0]}
  fi

  "$@"
}

note_command() {
  init_stdout_style
  if stdout_supports_color; then
    printf '  '
    style_line "1;32" "$1"
    printf '\n'
  else
    printf '  %s\n' "$1"
  fi
}

warn() {
  printf '%s\n' "$*" >&2
}

print_help() {
  cat <<'EOF'
wt - thin git worktree helper for Node.js repositories

Usage:
  wt new [branch]
  wt init
  wt b [branch-or-handle]
  wt cd <branch-or-handle>
  wt open <branch-or-handle>
  wt sync
  wt merge
  wt rm [--force] [branch-or-handle]
  wt ls
  wt help

Commands:
  new    Create or attach a worktree; with no branch, ask and suggest one
  init   Generate or update .vscode/launch.json for the current worktree
  b      Open the current or requested worktree in the debug browser
  cd     Print the absolute path for a linked worktree
  open   Print the absolute path for a linked worktree
  sync   Merge the primary branch into the current linked worktree
  merge  Merge the current linked worktree into the primary branch and clean up
  rm     Remove a linked worktree conservatively
  ls     List the primary checkout and linked worktrees

Notes:
  - Run wt from inside the repository you want to manage.
  - wt never starts a dev server.
  - wt deletes linked branches when removal is safe.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_git_repo() {
  require_command git
  if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    die "wt must be run inside a Git repository"
  fi
}

get_repo_root() {
  git rev-parse --show-toplevel
}

get_main_repo_root() {
  local common_dir
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git rev-parse --git-common-dir)
  common_dir=$(cd "$common_dir" && pwd -P)
  dirname "$common_dir"
}

get_primary_branch() {
  local repo_root branch
  repo_root=${1:-$(get_main_repo_root)}
  branch=$(git -C "$repo_root" branch --show-current 2>/dev/null || true)
  [ -n "$branch" ] || die "Unable to determine the primary branch from: $repo_root (the primary worktree may be on a detached HEAD)"
  printf '%s\n' "$branch"
}

get_repo_name() {
  basename "$(get_main_repo_root)"
}

get_worktree_root() {
  local repo_root parent_dir repo_name
  repo_root=$(get_main_repo_root)
  parent_dir=$(dirname "$repo_root")
  repo_name=$(basename "$repo_root")
  printf '%s\n' "$parent_dir/${repo_name}__worktrees"
}

get_debug_port() {
  local port
  port=${WT_DEBUG_PORT-$WT_DEBUG_PORT_DEFAULT}
  case "$port" in
    ''|*[!0-9]*) die "Invalid WT_DEBUG_PORT: $port" ;;
  esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "Invalid WT_DEBUG_PORT: $port"
  printf '%s\n' "$port"
}

get_debug_user_data_dir() {
  if [ -n "${WT_DEBUG_USER_DATA_DIR-}" ]; then
    printf '%s\n' "$WT_DEBUG_USER_DATA_DIR"
    return 0
  fi

  [ -n "${HOME-}" ] || die "HOME is required to resolve the debug browser userDataDir"
  printf '%s\n' "$HOME/.vscode/chrome"
}

trim_leading_dashes() {
  local value="$1"
  while [ -n "$value" ] && [ "${value#-}" != "$value" ]; do
    value=${value#-}
  done
  printf '%s\n' "$value"
}

trim_trailing_dashes() {
  local value="$1"
  while [ -n "$value" ] && [ "${value%-}" != "$value" ]; do
    value=${value%-}
  done
  printf '%s\n' "$value"
}

normalize_handle() {
  local branch lowered collapsed
  branch=${1-}
  [ -n "$branch" ] || die "A branch name is required"

  lowered=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]')
  collapsed=$(printf '%s' "$lowered" | sed -e 's#[/[:space:]]#-#g' -e 's#[^a-z0-9._-]#-#g' -e 's#-\{2,\}#-#g')
  collapsed=$(trim_leading_dashes "$collapsed")
  collapsed=$(trim_trailing_dashes "$collapsed")

  [ -n "$collapsed" ] || die "Unable to derive a filesystem handle from branch: $branch"
  printf '%s\n' "$collapsed"
}

branch_exists_locally() {
  local repo_root branch
  repo_root=$1
  branch=$2
  git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"
}

read_package_manager_field() {
  local package_json value
  package_json=$1
  [ -f "$package_json" ] || return 0
  value=$(tr -d '\n\r' <"$package_json" | sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  printf '%s\n' "$value"
}

detect_package_manager() {
  local root package_manager_field
  root=$1

  if [ -f "$root/pnpm-lock.yaml" ]; then
    printf '%s\n' "pnpm"
    return 0
  fi
  if [ -f "$root/package-lock.json" ]; then
    printf '%s\n' "npm"
    return 0
  fi
  if [ -f "$root/bun.lock" ] || [ -f "$root/bun.lockb" ]; then
    printf '%s\n' "bun"
    return 0
  fi

  package_manager_field=$(read_package_manager_field "$root/package.json")
  case "$package_manager_field" in
    pnpm@*) printf '%s\n' "pnpm" ;;
    npm@*) printf '%s\n' "npm" ;;
    bun@*) printf '%s\n' "bun" ;;
    *) printf '%s\n' "" ;;
  esac
}

require_python3() {
  require_command python3
}
