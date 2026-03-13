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

assert_contains() {
  local haystack needle message
  haystack=$1
  needle=$2
  message=$3
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$message\nmissing: $needle\nin: $haystack" ;;
  esac
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

commit_repo_state() {
  local repo message
  repo=$1
  message=$2
  git -C "$repo" add . >/dev/null
  git -C "$repo" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "$message" >/dev/null
}

write_portless_package_json() {
  local repo package_name dev_script
  repo=$1
  package_name=$2
  dev_script=$3
  cat >"$repo/package.json" <<EOF
{
  "name": "$package_name",
  "private": true,
  "scripts": {
    "dev": "$dev_script"
  }
}
EOF
}

make_fake_portless_bin() {
  local dir
  dir=$(mktemp -d)
  cat >"$dir/portless" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${WT_TEST_PORTLESS_LOG:-}" != "" ]; then
  printf '%s\t%s\t%s\n' "$PWD" "$1" "${2-}" >>"$WT_TEST_PORTLESS_LOG"
fi

case "${1-}" in
  get)
    name=${2-}
    [ -n "$name" ] || exit 1
    prefix=""
    case "$PWD" in
      *__worktrees/*)
        prefix="$(basename "$PWD")."
        ;;
    esac
    printf 'https://%s%s.localhost:1355\n' "$prefix" "$name"
    ;;
  *)
    printf 'unsupported fake portless command: %s\n' "${1-}" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$dir/portless"
  printf '%s\n' "$dir"
}

make_fake_browser_bin() {
  local dir
  dir=$(mktemp -d)
  cat >"$dir/fake-chrome" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${WT_TEST_BROWSER_LOG:-}" != "" ]; then
  printf '%s\n' "$*" >>"$WT_TEST_BROWSER_LOG"
fi

port=""
for arg in "$@"; do
  case "$arg" in
    --remote-debugging-port=*)
      port=${arg#--remote-debugging-port=}
      ;;
  esac
done

if [ -n "$port" ] && [ "${WT_TEST_BROWSER_AUTOLISTEN:-}" = "1" ]; then
  python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
  pid=$!
  if [ "${WT_TEST_BROWSER_PIDS:-}" != "" ]; then
    printf '%s\n' "$pid" >>"$WT_TEST_BROWSER_PIDS"
  fi
  sleep 0.3
fi
EOF
  chmod +x "$dir/fake-chrome"
  printf '%s\n' "$dir/fake-chrome"
}

cleanup_pids_file() {
  local file pid
  file=$1
  [ -f "$file" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done <"$file"
}

free_port() {
  python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

assert_launch_json() {
  local launch_path expected_url expected_port expected_extra_name
  launch_path=$1
  expected_url=$2
  expected_port=$3
  expected_extra_name=${4-}
  python3 - "$launch_path" "$expected_url" "$expected_port" "$expected_extra_name" <<'PY'
import json
import sys

launch_path, expected_url, expected_port, expected_extra_name = sys.argv[1:5]
with open(launch_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

assert data["version"] == "0.2.0"
configs = data["configurations"]
assert isinstance(configs, list) and configs
managed = configs[0]
assert managed["name"] == "wt: attach browser"
assert managed["request"] == "attach"
assert managed["type"] == "chrome"
assert managed["url"] == expected_url
assert managed["port"] == int(expected_port)
assert managed["webRoot"] == "${workspaceFolder}"
assert managed["internalConsoleOptions"] == "neverOpen"
if expected_extra_name:
    names = [config.get("name") for config in configs if isinstance(config, dict)]
    assert expected_extra_name in names
for config in configs:
    if isinstance(config, dict) and config.get("request") == "launch" and config.get("type") in {"chrome", "msedge", "edge", "pwa-chrome", "pwa-msedge"}:
        raise AssertionError(f"browser launch config remained: {config}")
PY
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

test_init_creates_launch_json_for_explicit_portless_name() {
  local repo fake_bin portless_log
  repo=$(make_repo)
  write_portless_package_json "$repo" "guidance-studio" "portless myapp pnpm dev"
  fake_bin=$(make_fake_portless_bin)
  portless_log=$(mktemp)

  (cd "$repo" && PATH="$fake_bin:$PATH" WT_TEST_PORTLESS_LOG="$portless_log" bash "$ROOT/bin/wt" init >/dev/null)

  assert_launch_json "$repo/.vscode/launch.json" "https://myapp.localhost:1355" "9222"
  assert_contains "$(cat "$portless_log")" $'\tget\tmyapp' "wt init should ask portless for the explicit app name"
}

test_init_preserves_unrelated_configs_and_removes_browser_launch() {
  local repo fake_bin
  repo=$(make_repo)
  write_portless_package_json "$repo" "guidance-studio" "portless myapp pnpm dev"
  mkdir -p "$repo/.vscode"
  cat >"$repo/.vscode/launch.json" <<'EOF'
{
  "version": "0.2.0",
  "compounds": [
    {
      "name": "full stack",
      "configurations": ["server"]
    }
  ],
  "configurations": [
    {
      "type": "chrome",
      "request": "launch",
      "name": "client",
      "url": "https://stale.localhost:1355"
    },
    {
      "type": "node",
      "request": "launch",
      "name": "server",
      "program": "${workspaceFolder}/server.js"
    }
  ]
}
EOF
  fake_bin=$(make_fake_portless_bin)

  (cd "$repo" && PATH="$fake_bin:$PATH" bash "$ROOT/bin/wt" init >/dev/null)

  assert_launch_json "$repo/.vscode/launch.json" "https://myapp.localhost:1355" "9222" "server"
  python3 - "$repo/.vscode/launch.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
assert data["compounds"][0]["name"] == "full stack"
PY
}

test_init_derives_name_for_portless_run() {
  local repo fake_bin portless_log
  repo=$(make_repo)
  write_portless_package_json "$repo" "guidance-studio" "portless run pnpm dev"
  fake_bin=$(make_fake_portless_bin)
  portless_log=$(mktemp)

  (cd "$repo" && PATH="$fake_bin:$PATH" WT_TEST_PORTLESS_LOG="$portless_log" bash "$ROOT/bin/wt" init >/dev/null)

  assert_launch_json "$repo/.vscode/launch.json" "https://guidance-studio.localhost:1355" "9222"
  assert_contains "$(cat "$portless_log")" $'\tget\tguidance-studio' "wt init should infer the base app name for portless run"
}

test_b_starts_debug_browser_for_current_worktree() {
  local repo fake_bin chrome_bin browser_log browser_pids debug_port user_data_dir log_line
  repo=$(make_repo)
  write_portless_package_json "$repo" "guidance-studio" "portless run --name guidance env -u HOST nuxt dev"
  fake_bin=$(make_fake_portless_bin)
  chrome_bin=$(make_fake_browser_bin)
  browser_log=$(mktemp)
  browser_pids=$(mktemp)
  debug_port=$(free_port)
  user_data_dir=$(mktemp -d)

  (
    cd "$repo" && \
    PATH="$fake_bin:$PATH" \
    WT_CHROME_BIN="$chrome_bin" \
    WT_DEBUG_PORT="$debug_port" \
    WT_DEBUG_USER_DATA_DIR="$user_data_dir" \
    WT_TEST_BROWSER_LOG="$browser_log" \
    WT_TEST_BROWSER_AUTOLISTEN=1 \
    WT_TEST_BROWSER_PIDS="$browser_pids" \
    bash "$ROOT/bin/wt" b >/dev/null
  )

  log_line=$(cat "$browser_log")
  assert_contains "$log_line" "--remote-debugging-port=$debug_port" "wt b should launch Chrome with the fixed debug port"
  assert_contains "$log_line" "--user-data-dir=$user_data_dir" "wt b should launch Chrome with the configured userDataDir"
  assert_contains "$log_line" "https://guidance.localhost:1355" "wt b should open the current worktree URL"
  cleanup_pids_file "$browser_pids"
}

test_b_reuses_debug_browser_for_requested_worktree() {
  local repo fake_bin chrome_bin browser_log debug_port server_pid
  repo=$(make_repo)
  write_portless_package_json "$repo" "guidance-studio" "portless myapp pnpm dev"
  commit_repo_state "$repo" "add package"
  git -C "$repo" worktree add "${repo}__worktrees/feature-test" -b feature/test >/dev/null
  fake_bin=$(make_fake_portless_bin)
  chrome_bin=$(make_fake_browser_bin)
  browser_log=$(mktemp)
  debug_port=$(free_port)
  python3 -m http.server "$debug_port" --bind 127.0.0.1 >/dev/null 2>&1 &
  server_pid=$!

  (
    cd "$repo" && \
    PATH="$fake_bin:$PATH" \
    WT_CHROME_BIN="$chrome_bin" \
    WT_DEBUG_PORT="$debug_port" \
    WT_TEST_BROWSER_LOG="$browser_log" \
    bash "$ROOT/bin/wt" b feature/test >/dev/null
  )

  sleep 0.2
  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true
  assert_eq "https://feature-test.myapp.localhost:1355" "$(cat "$browser_log")" "wt b should reuse the browser and open the requested worktree URL"
}

test_new_runs_init_for_portless_worktree() {
  local repo fake_bin
  repo=$(make_repo)
  write_portless_package_json "$repo" "guidance-studio" "portless run --name guidance env -u HOST nuxt dev"
  commit_repo_state "$repo" "add package"
  fake_bin=$(make_fake_portless_bin)

  (cd "$repo" && PATH="$fake_bin:$PATH" bash "$ROOT/bin/wt" new feature/test >/dev/null)

  assert_launch_json "${repo}__worktrees/feature-test/.vscode/launch.json" "https://feature-test.guidance.localhost:1355" "9222"
}

test_cd_matches_open
test_wrapper_cd_changes_directory
test_wrapper_new_changes_directory
test_wrapper_cd_missing_target_keeps_shell_alive
test_zsh_wrapper_cd_changes_directory
test_zsh_wrapper_new_changes_directory
test_cd_missing_target_fails
test_ls_shows_branch_first
test_init_creates_launch_json_for_explicit_portless_name
test_init_preserves_unrelated_configs_and_removes_browser_launch
test_init_derives_name_for_portless_run
test_b_starts_debug_browser_for_current_worktree
test_b_reuses_debug_browser_for_requested_worktree
test_new_runs_init_for_portless_worktree

printf 'smoke tests passed\n'
