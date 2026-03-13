#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected actual message
  expected=$1
  actual=$2
  message=$3
  if [ "$expected" != "$actual" ]; then
    fail "$message\nexpected: $expected\nactual:   $actual"
  fi
}

make_repo() {
  local base repo
  base=$(mktemp -d)
  repo="$base/repo with spaces"
  mkdir -p "$repo"
  git -C "$repo" init -b main >/dev/null
  git -C "$repo" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit --allow-empty -m init >/dev/null
  printf '%s\n' "$repo"
}

test_cd_matches_open() {
  local repo expected actual
  repo=$(make_repo)
  git -C "$repo" worktree add "${repo}__worktrees/feature-test" -b feature/test >/dev/null

  expected=$(cd "$repo" && bash "$ROOT/bin/wt" open feature/test)
  actual=$(cd "$repo" && bash "$ROOT/bin/wt" cd feature/test)
  assert_eq "$expected" "$actual" "wt cd should print the same path as wt open"
}

test_wrapper_cd_changes_directory() {
  local repo expected actual
  repo=$(make_repo)
  git -C "$repo" worktree add "${repo}__worktrees/feature-test" -b feature/test >/dev/null
  expected=$(cd "$repo" && bash "$ROOT/bin/wt" open feature/test)

  actual=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$repo"
wt cd feature/test >/dev/null
pwd -P
EOF
)

  assert_eq "$expected" "$actual" "sourced wrapper should cd into the requested worktree"
}

test_wrapper_new_changes_directory() {
  local repo expected actual
  repo=$(make_repo)

  actual=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$repo"
wt new feature/test >/dev/null
pwd -P
EOF
)

  expected=$(cd "${repo}__worktrees/feature-test" && pwd -P)

  assert_eq "$expected" "$actual" "sourced wrapper should cd into the new worktree"
}

test_wrapper_cd_missing_target_keeps_shell_alive() {
  local repo actual expected
  repo=$(make_repo)
  expected=$(cd "$repo" && pwd -P)

  actual=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$repo"
if wt cd does-not-exist >/dev/null 2>&1; then
  printf 'unexpected-success\n'
else
  pwd -P
fi
EOF
)

  assert_eq "$expected" "$actual" "failed wt cd should not kill the shell or change cwd"
}

test_zsh_wrapper_cd_changes_directory() {
  local repo expected actual
  repo=$(make_repo)
  git -C "$repo" worktree add "${repo}__worktrees/feature-test" -b feature/test >/dev/null
  expected=$(cd "$repo" && bash "$ROOT/bin/wt" open feature/test)

  actual=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" zsh <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$repo"
wt cd feature/test >/dev/null
pwd -P
EOF
)

  assert_eq "$expected" "$actual" "zsh wrapper should cd into the requested worktree"
}

test_zsh_wrapper_new_changes_directory() {
  local repo expected actual
  repo=$(make_repo)

  actual=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" zsh <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$repo"
wt new feature/test >/dev/null
pwd -P
EOF
)

  expected=$(cd "${repo}__worktrees/feature-test" && pwd -P)

  assert_eq "$expected" "$actual" "zsh wrapper should cd into the new worktree"
}

test_cd_missing_target_fails() {
  local repo
  repo=$(make_repo)

  if (cd "$repo" && bash "$ROOT/bin/wt" cd does-not-exist >/dev/null 2>&1); then
    fail "wt cd should fail for a missing target"
  fi
}

test_ls_shows_branch_first() {
  local repo output header
  repo=$(make_repo)
  git -C "$repo" worktree add "${repo}__worktrees/feature-test" -b feature/test >/dev/null

  output=$(cd "$repo" && bash "$ROOT/bin/wt" ls)
  header=$(printf '%s\n' "$output" | /usr/bin/awk 'NR==1 { print $1 " " $2 " " $3 " " $4 }')
  assert_eq "BRANCH HANDLE TYPE STATE" "$header" "wt ls should show branch first"
}

test_cd_matches_open
test_wrapper_cd_changes_directory
test_wrapper_new_changes_directory
test_wrapper_cd_missing_target_keeps_shell_alive
test_zsh_wrapper_cd_changes_directory
test_zsh_wrapper_new_changes_directory
test_cd_missing_target_fails
test_ls_shows_branch_first

printf 'smoke tests passed\n'
