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

assert_not_contains() {
  local haystack needle message
  haystack=$1
  needle=$2
  message=$3
  case "$haystack" in
    *"$needle"*) fail "$message\nunexpected: $needle\nin: $haystack" ;;
    *) ;;
  esac
}

assert_in_order() {
  local haystack first second message
  haystack=$1
  first=$2
  second=$3
  message=$4
  python3 - "$haystack" "$first" "$second" "$message" <<'PY'
import sys

haystack, first, second, message = sys.argv[1:5]
first_index = haystack.find(first)
second_index = haystack.find(second)
if first_index == -1 or second_index == -1 or first_index >= second_index:
    raise SystemExit(f"{message}\nfirst:  {first}\nsecond: {second}\ntext: {haystack}")
PY
}

assert_file_exists() {
  local path message
  path=$1
  message=$2
  [ -e "$path" ] || fail "$message\nmissing path: $path"
}

assert_file_missing() {
  local path message
  path=$1
  message=$2
  [ ! -e "$path" ] || fail "$message\npath still exists: $path"
}

make_repo() {
  local base repo primary_branch
  base=$(mktemp -d)
  repo="$base/repo with spaces"
  primary_branch=${1:-main}
  mkdir -p "$repo"
  git -C "$repo" init -b "$primary_branch" >/dev/null
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

make_fake_npm_bin() {
  local dir
  dir=$(mktemp -d)
  cat >"$dir/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'WT_TEST_NPM install %s\n' "$*"
EOF
  chmod +x "$dir/npm"
  printf '%s\n' "$dir"
}

make_fake_opencode_bin() {
  local dir
  dir=$(mktemp -d)
  cat >"$dir/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

python3 - "${WT_TEST_OPENCODE_LOG-}" "$@" <<'PY'
import json
import sys

log_path = sys.argv[1]
args = sys.argv[2:]
if log_path:
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(args) + "\n")
PY

if [ "${1-}" != "run" ]; then
  if [ "${WT_TEST_OPENCODE_STDOUT_MARKER-}" != "" ]; then
    printf '%s\n' "$WT_TEST_OPENCODE_STDOUT_MARKER"
  fi
  exit 0
fi

branch=${WT_TEST_OPENCODE_BRANCH:-feat/default-branch}
python3 - "$branch" <<'PY'
import json
import sys

branch = sys.argv[1]
print(json.dumps({"type": "step_start", "part": {"type": "step-start"}}))
print(json.dumps({"type": "text", "part": {"type": "text", "text": branch}}))
print(json.dumps({"type": "step_finish", "part": {"type": "step-finish", "reason": "stop"}}))
PY
EOF
  chmod +x "$dir/opencode"
  printf '%s\n' "$dir"
}

assert_opencode_log_count() {
  local log_path expected_count message
  log_path=$1
  expected_count=$2
  message=$3
  python3 - "$log_path" "$expected_count" "$message" <<'PY'
import json
import sys

log_path, expected_count, message = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(log_path, "r", encoding="utf-8") as handle:
    lines = [line for line in handle.read().splitlines() if line.strip()]
if len(lines) != expected_count:
    raise SystemExit(f"{message}\nexpected count: {expected_count}\nactual count:   {len(lines)}")
for line in lines:
    json.loads(line)
PY
}

assert_opencode_log_invocation_contains() {
  local log_path index message
  log_path=$1
  index=$2
  message=$3
  shift 3
  python3 - "$log_path" "$index" "$message" "$@" <<'PY'
import json
import sys

log_path = sys.argv[1]
index = int(sys.argv[2])
message = sys.argv[3]
expected_args = sys.argv[4:]

with open(log_path, "r", encoding="utf-8") as handle:
    lines = [line for line in handle.read().splitlines() if line.strip()]

if index >= len(lines):
    raise SystemExit(f"{message}\nmissing invocation index: {index}\nactual count: {len(lines)}")

invocation = json.loads(lines[index])
for expected in expected_args:
    if expected not in invocation:
        raise SystemExit(f"{message}\nmissing arg: {expected}\ninvocation: {invocation}")
PY
}

run_in_pty() {
  local input
  input=$1
  shift

  python3 - "$input" "$@" <<'PY'
import os
import pty
import select
import subprocess
import sys
import time

input_data = sys.argv[1].encode("utf-8")
command = sys.argv[2:]

master_fd, slave_fd = pty.openpty()
proc = subprocess.Popen(command, stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, close_fds=True)
os.close(slave_fd)

if input_data:
    time.sleep(0.1)
    os.write(master_fd, input_data)

chunks = []
while True:
    ready, _, _ = select.select([master_fd], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(master_fd, 4096)
        except OSError:
            chunk = b""
        if chunk:
            chunks.append(chunk)
        elif proc.poll() is not None:
            break
    elif proc.poll() is not None:
        try:
            chunk = os.read(master_fd, 4096)
        except OSError:
            chunk = b""
        if chunk:
            chunks.append(chunk)
            continue
        break

os.close(master_fd)
sys.stdout.buffer.write(b"".join(chunks))
sys.exit(proc.wait())
PY
}

render_terminal_output() {
  python3 - "$1" <<'PY'
import sys

text = sys.argv[1]
lines = [[]]
row = 0
col = 0
i = 0

def ensure_row(target: int) -> None:
    while len(lines) <= target:
        lines.append([])

def clear_to_end() -> None:
    line = lines[row]
    del line[col:]

while i < len(text):
    ch = text[i]

    if ch == "\x1b" and i + 1 < len(text) and text[i + 1] == "[":
        j = i + 2
        while j < len(text) and text[j] not in "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~":
            j += 1
        if j >= len(text):
            break
        cmd = text[j]
        if cmd == "K":
            clear_to_end()
        i = j + 1
        continue

    if ch == "\r":
        col = 0
        i += 1
        continue

    if ch == "\n":
        row += 1
        ensure_row(row)
        col = 0
        i += 1
        continue

    if ch == "\b":
        if col > 0:
            col -= 1
        i += 1
        continue

    if ch == "\a":
        i += 1
        continue

    ensure_row(row)
    line = lines[row]
    if col == len(line):
        line.append(ch)
    else:
        line[col] = ch
    col += 1
    i += 1

print("\n".join("".join(line).rstrip() for line in lines))
PY
}

make_fake_opencode_merge_bin() {
  local dir
  dir=$(mktemp -d)
  cat >"$dir/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

python3 - "${WT_TEST_OPENCODE_LOG-}" "$@" <<'PY'
import json
import sys

log_path = sys.argv[1]
args = sys.argv[2:]
if log_path:
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(args) + "\n")
PY

target_dir=${1-}

[ -n "$target_dir" ] || exit 1

cd "$target_dir"
for file in $(git diff --name-only --diff-filter=U); do
  python3 - "$file" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r") as f:
    lines = f.readlines()

result = []
skip = False
for line in lines:
    if line.startswith("<<<<<<<"):
        continue
    if line.startswith("======="):
        skip = True
        continue
    if line.startswith(">>>>>>>"):
        skip = False
        continue
    if not skip:
        result.append(line)

with open(path, "w") as f:
    f.writelines(result)
PY
  git add "$file"
done

GIT_EDITOR=: git -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false merge --continue
EOF
  chmod +x "$dir/opencode"
  printf '%s\n' "$dir"
}

make_fake_opencode_noop_bin() {
  local dir
  dir=$(mktemp -d)
  cat >"$dir/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$dir/opencode"
  printf '%s\n' "$dir"
}

make_fake_devtools_bin() {
  local dir
  dir=$(mktemp -d)
  cat >"$dir/fake-devtools" <<'EOF'
#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])
ready_delay = float(os.environ.get("WT_TEST_DEVTOOLS_READY_DELAY", "0"))
if ready_delay > 0:
    time.sleep(ready_delay)

log_path = os.environ.get("WT_TEST_DEVTOOLS_LOG", "")


def log_request(method: str, url: str) -> None:
    if not log_path:
        return
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(f"{method}\t{url}\n")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/json/version":
            payload = {
                "Browser": "FakeChrome/1.0",
                "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/browser/fake",
            }
            body = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path == "/json/new":
            url = urllib.parse.unquote(parsed.query)
            log_request("GET", url)
            payload = {"id": "page-1", "url": url}
            body = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()

    def do_PUT(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/json/new":
            url = urllib.parse.unquote(parsed.query)
            log_request("PUT", url)
            payload = {"id": "page-1", "url": url}
            body = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, format: str, *args) -> None:
        return


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
EOF
  chmod +x "$dir/fake-devtools"
  printf '%s\n' "$dir/fake-devtools"
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
  "${WT_TEST_FAKE_DEVTOOLS_BIN:?WT_TEST_FAKE_DEVTOOLS_BIN is required when WT_TEST_BROWSER_AUTOLISTEN=1}" "$port" >/dev/null 2>&1 &
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
assert managed["urlFilter"] == f"{expected_url}/*"
assert "url" not in managed
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

test_new_without_args_accepts_opencode_suggestion() {
  local repo fake_bin opencode_log output prompt_log
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  output=$(
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_BRANCH_NAME_MODEL='' \
      WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      run_in_pty $'add a guided onboarding flow\n\nn\n' bash "$ROOT/bin/wt" new
  )

  assert_file_exists "${repo}__worktrees/feat-generated-branch" "wt new without args should create the suggested worktree"
  assert_contains "$output" "Created worktree" "wt new without args should group the creation summary under a readable heading"
  assert_contains "$output" "Worktree" "wt new without args should group git worktree setup progress under a readable heading"
  assert_not_contains "$output" "Next steps" "wt new should no longer print a separate next steps section"
  assert_contains "$output" "branch: feat/generated-branch" "wt new without args should use the suggested branch by default"
  prompt_log=$(cat "$opencode_log")
  assert_contains "$prompt_log" "opencode-go/kimi-k2.5" "wt new without args should request the dedicated branch-name model"
  assert_contains "$prompt_log" "add a guided onboarding flow" "wt new without args should send the user's intent to OpenCode"
  assert_contains "$prompt_log" "Return exactly one Git branch name and nothing else." "wt new without args should constrain the OpenCode response"
}

test_new_without_args_honors_branch_name_model_override() {
  local repo fake_bin opencode_log output prompt_log
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  output=$(
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_BRANCH_NAME_MODEL="opencode-go/test-branch-model" \
      WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      run_in_pty $'add a guided onboarding flow\n\nn\n' bash "$ROOT/bin/wt" new
  )

  assert_file_exists "${repo}__worktrees/feat-generated-branch" "wt new without args should create the suggested worktree when the branch-name model is overridden"
  assert_contains "$output" "branch: feat/generated-branch" "wt new without args should still use the suggested branch when the branch-name model is overridden"
  prompt_log=$(cat "$opencode_log")
  assert_contains "$prompt_log" "opencode-go/test-branch-model" "wt new without args should honor WT_BRANCH_NAME_MODEL for branch suggestions"
}

test_new_without_args_allows_editing_suggestion() {
  local repo fake_bin output opencode_log
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  output=$(
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      run_in_pty $'investigate flaky login test\nfix/login-flake\nn\n' bash "$ROOT/bin/wt" new
  )

  assert_file_exists "${repo}__worktrees/fix-login-flake" "wt new without args should create the edited branch worktree"
  assert_contains "$output" "branch: fix/login-flake" "wt new without args should use the edited branch name"
}

test_new_without_args_handles_multibyte_backspace_in_goal_prompt() {
  local repo fake_bin opencode_log output prompt_log
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  output=$(
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      run_in_pty $'あ\177add a guided onboarding flow\n\nn\n' bash "$ROOT/bin/wt" new
  )

  assert_file_exists "${repo}__worktrees/feat-generated-branch" "wt new without args should still create the suggested worktree after multibyte backspace in the goal prompt"
  prompt_log=$(cat "$opencode_log")
  assert_contains "$prompt_log" "User intent: add a guided onboarding flow" "wt new should pass the cleaned goal to OpenCode after multibyte backspace"
  assert_not_contains "$prompt_log" "User intent: あ" "wt new should not leak partial multibyte input into the OpenCode goal prompt"
  assert_contains "$output" "branch: feat/generated-branch" "wt new should keep using the suggested branch after multibyte backspace in the goal prompt"
}

test_new_without_args_keeps_goal_prompt_visible_after_excess_backspace() {
  local repo fake_bin opencode_log output rendered_output
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  output=$(
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      run_in_pty $'abc\177\177\177\177\177add a guided onboarding flow\n\nn\n' bash "$ROOT/bin/wt" new
  )
  rendered_output=$(render_terminal_output "$output")

  assert_file_exists "${repo}__worktrees/feat-generated-branch" "wt new should still create the suggested worktree after excess backspace in the goal prompt"
  assert_contains "$rendered_output" "What do you want to do in this worktree? add a guided onboarding flow" "wt new should keep the goal prompt text visible after excess backspace"
  assert_contains "$output" "branch: feat/generated-branch" "wt new should still use the suggested branch after excess backspace in the goal prompt"
}

test_new_without_args_handles_multibyte_backspace_in_branch_prompt() {
  local repo fake_bin output opencode_log
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  output=$(
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      run_in_pty $'investigate flaky login test\nあ\177fix/login-flake\nn\n' bash "$ROOT/bin/wt" new
  )

  assert_file_exists "${repo}__worktrees/fix-login-flake" "wt new should create the edited branch worktree after multibyte backspace in the branch prompt"
  assert_contains "$output" "branch: fix/login-flake" "wt new should accept the cleaned branch name after multibyte backspace"
}

test_new_without_args_keeps_branch_prompt_visible_after_excess_backspace() {
  local repo fake_bin output opencode_log rendered_output
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  output=$(
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      run_in_pty $'investigate flaky login test\nabc\177\177\177\177\177fix/login-flake\nn\n' bash "$ROOT/bin/wt" new
  )
  rendered_output=$(render_terminal_output "$output")

  assert_file_exists "${repo}__worktrees/fix-login-flake" "wt new should create the edited branch worktree after excess backspace in the branch prompt"
  assert_contains "$rendered_output" "Branch name [feat/generated-branch]: fix/login-flake" "wt new should keep the branch prompt text visible after excess backspace"
  assert_contains "$output" "branch: fix/login-flake" "wt new should keep the edited branch name after excess backspace in the branch prompt"
}

test_new_without_args_requires_interactive_terminal() {
  local repo output fake_bin
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)

  if output=$(cd "$repo" && printf 'add a guided onboarding flow\n' | PATH="$fake_bin:$PATH" bash "$ROOT/bin/wt" new 2>&1 >/dev/null); then
    fail "wt new without args should fail outside an interactive terminal"
  fi

  assert_contains "$output" "wt new without a branch requires an interactive terminal" "wt new without args should explain the tty requirement"
}

test_new_without_args_launches_opencode_when_confirmed() {
  local repo fake_bin opencode_log output expected_worktree
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  output=$(
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_NEW_WORKTREE_AGENT='' \
      WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      WT_TEST_OPENCODE_STDOUT_MARKER="WT_TEST_OPENCODE_INTERACTIVE" \
      run_in_pty $'add a guided onboarding flow\n\ny\n' bash "$ROOT/bin/wt" new
  )

  expected_worktree=$(cd "${repo}__worktrees/feat-generated-branch" && pwd -P)

  assert_file_exists "${repo}__worktrees/feat-generated-branch" "wt new should create the suggested worktree before launching opencode"
  assert_contains "$output" "WT_TEST_OPENCODE_INTERACTIVE" "wt new should attach the launched opencode session to the terminal"
  assert_opencode_log_count "$opencode_log" 2 "wt new should call opencode twice when launch is confirmed"
  assert_opencode_log_invocation_contains "$opencode_log" 1 "wt new should launch opencode in the new worktree with the original goal" "$expected_worktree" "--agent" "Build" "--prompt" "add a guided onboarding flow"
}

test_new_without_args_skips_opencode_when_declined() {
  local repo fake_bin opencode_log output
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  output=$(
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      run_in_pty $'add a guided onboarding flow\n\nn\n' bash "$ROOT/bin/wt" new
  )

  assert_file_exists "${repo}__worktrees/feat-generated-branch" "wt new should still create the worktree when opencode launch is declined"
  assert_contains "$output" "branch: feat/generated-branch" "wt new should still report the created branch when launch is declined"
  assert_opencode_log_count "$opencode_log" 1 "wt new should only call opencode for branch generation when launch is declined"
}

test_new_without_args_repompts_for_invalid_launch_confirmation() {
  local repo fake_bin opencode_log output
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  output=$(
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      run_in_pty $'add a guided onboarding flow\n\nmaybe\nn\n' bash "$ROOT/bin/wt" new
  )

  assert_contains "$output" "Please answer y or n" "wt new should reprompt for invalid launch confirmation input"
  assert_opencode_log_count "$opencode_log" 1 "wt new should not launch opencode after invalid input followed by n"
}

test_new_without_args_launches_opencode_with_original_goal_after_branch_edit() {
  local repo fake_bin opencode_log expected_worktree
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  (
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_NEW_WORKTREE_AGENT='' \
      WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      run_in_pty $'investigate flaky login test\nfix/login-flake\ny\n' bash "$ROOT/bin/wt" new >/dev/null
  )

  expected_worktree=$(cd "${repo}__worktrees/fix-login-flake" && pwd -P)

  assert_file_exists "${repo}__worktrees/fix-login-flake" "wt new should create the edited branch worktree before launching opencode"
  assert_opencode_log_count "$opencode_log" 2 "wt new should still launch opencode after editing the branch name"
  assert_opencode_log_invocation_contains "$opencode_log" 1 "wt new should pass the original goal instead of the edited branch name" "$expected_worktree" "--agent" "Build" "--prompt" "investigate flaky login test"
}

test_new_with_explicit_branch_does_not_launch_opencode() {
  local repo fake_bin opencode_log
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  (
    cd "$repo" && \
      PATH="$fake_bin:$PATH" \
      WT_TEST_OPENCODE_LOG="$opencode_log" \
      bash "$ROOT/bin/wt" new feature/test >/dev/null
  )

  assert_file_exists "${repo}__worktrees/feature-test" "wt new with an explicit branch should still create the requested worktree"
  assert_opencode_log_count "$opencode_log" 0 "wt new with an explicit branch should not invoke opencode"
}

test_new_with_explicit_branch_is_plain_when_not_in_pty() {
  local repo output expected_worktree
  repo=$(make_repo)

  output=$(cd "$repo" && bash "$ROOT/bin/wt" new feature/test 2>&1)
  expected_worktree=$(cd "${repo}__worktrees/feature-test" && pwd -P)

  assert_not_contains "$output" $'\033[' "wt new should not emit ANSI colors when stdout is not a TTY"
  assert_contains "$output" "  worktree_path: $expected_worktree" "wt new should keep indented detail lines even when stdout is not a TTY"
}

test_new_with_explicit_branch_uses_cli_styling_in_pty() {
  local repo output rendered_output expected_worktree
  repo=$(make_repo)
  printf 'ROOT=1\n' >"$repo/.env"
  printf 'local config\n' >"$repo/.tool.local"

  output=$(cd "$repo" && run_in_pty '' bash "$ROOT/bin/wt" new feature/test)
  rendered_output=$(render_terminal_output "$output")
  expected_worktree=$(cd "${repo}__worktrees/feature-test" && pwd -P)

  assert_contains "$output" $'\033[' "wt new should emit ANSI colors when stdout is a TTY"
  assert_not_contains "$output" $'\033[0;33m' "wt new should not color worktree status lines yellow"
  assert_contains "$rendered_output" "==> Worktree" "wt new should render a CLI-style worktree progress section in a PTY"
  assert_contains "$rendered_output" "  -> Preparing worktree (new branch 'feature/test')" "wt new should show git worktree preparation as an indented status line"
  assert_contains "$rendered_output" "==> Created worktree" "wt new should render a CLI-style section heading in a PTY"
  assert_contains "$rendered_output" "  worktree_path: $expected_worktree" "wt new should indent detail lines in a PTY"
  assert_not_contains "$rendered_output" "  repo_root:" "wt new should not print the repo root in the created worktree section"
  assert_not_contains "$rendered_output" "  handle:" "wt new should not print the normalized handle in the created worktree section"
  assert_contains "$rendered_output" "  copied_entries: 2" "wt new should show a bootstrap parent detail before copied entries"
  assert_contains "$rendered_output" "    - copied: .env" "wt new should list copied bootstrap entries in a PTY"
  assert_contains "$rendered_output" "    - copied: .tool.local" "wt new should list copied local config entries in a PTY"
  assert_not_contains "$rendered_output" "==> Next steps" "wt new should no longer render a next steps section"
}

test_new_reports_worktree_before_dependency_install() {
  local repo fake_npm output
  repo=$(make_repo)
  printf '{"name":"demo","private":true}\n' >"$repo/package.json"
  printf '{}' >"$repo/package-lock.json"
  commit_repo_state "$repo" "add npm project"
  fake_npm=$(make_fake_npm_bin)

  output=$(cd "$repo" && PATH="$fake_npm:$PATH" bash "$ROOT/bin/wt" new feature/test 2>&1)

  assert_in_order "$output" "==> Worktree" "Installing dependencies with: npm install --prefer-offline" "wt new should print the worktree section before the install announcement"
  assert_in_order "$output" "Installing dependencies with: npm install --prefer-offline" "WT_TEST_NPM install install --prefer-offline" "wt new should print the install announcement before installer output"
  assert_contains "$output" $'\n\nInstalling dependencies with: npm install --prefer-offline\n\nWT_TEST_NPM install install --prefer-offline' "wt new should visually separate the install announcement from the worktree section and installer output"
}

test_wrapper_new_reports_worktree_before_dependency_install() {
  local repo fake_npm output rendered_output
  repo=$(make_repo)
  printf '{"name":"demo","private":true}\n' >"$repo/package.json"
  printf '{}' >"$repo/package-lock.json"
  commit_repo_state "$repo" "add npm project"
  fake_npm=$(make_fake_npm_bin)

  output=$(PATH="$fake_npm:/usr/bin:/bin:/usr/sbin:/sbin" run_in_pty '' bash -lc 'source "$1/shell/wt.bash" && cd "$2" && wt new feature/test' bash "$ROOT" "$repo")
  rendered_output=$(render_terminal_output "$output")

  assert_in_order "$rendered_output" "==> Worktree" "Installing dependencies with: npm install --prefer-offline" "wrapper wt new should print the worktree section before the install announcement"
  assert_in_order "$rendered_output" "Installing dependencies with: npm install --prefer-offline" "WT_TEST_NPM install install --prefer-offline" "wrapper wt new should print the install announcement before installer output"
  assert_contains "$output" $'\033[2mWT_TEST_NPM install install --prefer-offline\033[0m' "wrapper wt new should dim installer output in a PTY"
}

test_wrapper_new_with_explicit_branch_uses_cli_styling() {
  local repo output rendered_output expected_worktree
  repo=$(make_repo)

  output=$(run_in_pty '' bash -lc 'source "$1/shell/wt.bash" && cd "$2" && wt new feature/test' bash "$ROOT" "$repo")
  rendered_output=$(render_terminal_output "$output")
  expected_worktree=$(cd "${repo}__worktrees/feature-test" && pwd -P)

  assert_contains "$output" $'\033[' "wrapper wt new should preserve ANSI styling for interactive shells"
  assert_contains "$rendered_output" "==> Worktree" "wrapper wt new should print CLI-style worktree headings"
  assert_contains "$rendered_output" "==> Created worktree" "wrapper wt new should print CLI-style headings"
  assert_contains "$rendered_output" "  worktree_path: $expected_worktree" "wrapper wt new should keep indented detail lines visible"
}

test_new_copies_root_local_entries_for_worktree_bootstrap() {
  local repo output worktree
  repo=$(make_repo)
  mkdir -p "$repo/.agents/skills/base-skill"
  printf '# Base skill\n' >"$repo/.agents/skills/base-skill/SKILL.md"
  commit_repo_state "$repo" "add tracked skills directory"

  printf 'ROOT=1\n' >"$repo/.env"
  printf 'local config\n' >"$repo/.tool.local"
  printf '{"enabled":true}\n' >"$repo/settings.local.json"
  mkdir -p "$repo/.state.local"
  printf 'cached\n' >"$repo/.state.local/data.txt"
  mkdir -p "$repo/.agents/skills/foo-skill.local"
  printf '# Local skill\n' >"$repo/.agents/skills/foo-skill.local/SKILL.md"

  output=$(cd "$repo" && bash "$ROOT/bin/wt" new feature/test 2>&1)
  worktree="${repo}__worktrees/feature-test"

  assert_contains "$output" "Bootstrap" "wt new should print bootstrap details in a dedicated section"
  assert_contains "$output" "copied_entries: 5" "wt new should print a bootstrap parent detail before the copied entries list"
  assert_contains "$output" "copied: .env" "wt new should list copied bootstrap files"
  assert_contains "$output" "copied: .agents/skills/foo-skill.local" "wt new should list copied nested local directories"
  assert_file_exists "$worktree/.env" "wt new should copy the root .env file into the new worktree"
  assert_file_exists "$worktree/.tool.local" "wt new should copy root entries ending in .local"
  assert_file_exists "$worktree/settings.local.json" "wt new should copy root entries containing .local."
  assert_file_exists "$worktree/.state.local" "wt new should copy root directories ending in .local"
  assert_file_exists "$worktree/.state.local/data.txt" "wt new should copy the contents of root .local directories"
  assert_file_exists "$worktree/.agents/skills/foo-skill.local" "wt new should copy nested .local directories under tracked paths"
  assert_file_exists "$worktree/.agents/skills/foo-skill.local/SKILL.md" "wt new should copy files inside nested .local directories under tracked paths"
}

test_wrapper_new_without_args_changes_directory() {
  local repo expected actual fake_bin
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)

  actual=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
    run_in_pty $'add a guided onboarding flow\n\nn\n' \
    bash -lc 'source "$1/shell/wt.bash" && cd "$2" && wt new >/dev/null && pwd -P' bash "$ROOT" "$repo")

  expected=$(cd "${repo}__worktrees/feat-generated-branch" && pwd -P)

  assert_contains "$actual" "$expected" "sourced wrapper should cd into the AI-selected worktree"
}

test_wrapper_new_without_args_launches_opencode_and_changes_directory() {
  local repo expected actual fake_bin opencode_log
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  actual=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WT_NEW_WORKTREE_AGENT='' \
    WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
    WT_TEST_OPENCODE_LOG="$opencode_log" \
    WT_TEST_OPENCODE_STDOUT_MARKER="WT_TEST_OPENCODE_INTERACTIVE" \
    run_in_pty $'add a guided onboarding flow\n\ny\n' \
    bash -lc 'source "$1/shell/wt.bash" && cd "$2" && wt new >/dev/null && pwd -P' bash "$ROOT" "$repo")

  expected=$(cd "${repo}__worktrees/feat-generated-branch" && pwd -P)

  assert_contains "$actual" "$expected" "sourced wrapper should cd into the AI-selected worktree after launching opencode"
  assert_contains "$actual" "WT_TEST_OPENCODE_INTERACTIVE" "sourced wrapper should keep the opencode session attached to the terminal"
  assert_opencode_log_count "$opencode_log" 2 "sourced wrapper wt new should launch opencode after branch generation"
  assert_opencode_log_invocation_contains "$opencode_log" 1 "sourced wrapper wt new should launch opencode in the new worktree" "$expected" "--agent" "Build" "--prompt" "add a guided onboarding flow"
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

test_zsh_wrapper_new_without_args_changes_directory() {
  local repo expected actual fake_bin
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)

  actual=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
    run_in_pty $'add a guided onboarding flow\n\nn\n' \
    zsh -lc 'source "$1/shell/wt.bash" && cd "$2" && wt new >/dev/null && pwd -P' zsh "$ROOT" "$repo")

  expected=$(cd "${repo}__worktrees/feat-generated-branch" && pwd -P)

  assert_contains "$actual" "$expected" "zsh wrapper should cd into the AI-selected worktree"
}

test_zsh_wrapper_new_without_args_launches_opencode_and_changes_directory() {
  local repo expected actual fake_bin opencode_log
  repo=$(make_repo)
  fake_bin=$(make_fake_opencode_bin)
  opencode_log=$(mktemp)

  actual=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WT_NEW_WORKTREE_AGENT='' \
    WT_TEST_OPENCODE_BRANCH="feat/generated-branch" \
    WT_TEST_OPENCODE_LOG="$opencode_log" \
    WT_TEST_OPENCODE_STDOUT_MARKER="WT_TEST_OPENCODE_INTERACTIVE" \
    run_in_pty $'add a guided onboarding flow\n\ny\n' \
    zsh -lc 'source "$1/shell/wt.bash" && cd "$2" && wt new >/dev/null && pwd -P' zsh "$ROOT" "$repo")

  expected=$(cd "${repo}__worktrees/feat-generated-branch" && pwd -P)

  assert_contains "$actual" "$expected" "zsh wrapper should cd into the AI-selected worktree after launching opencode"
  assert_contains "$actual" "WT_TEST_OPENCODE_INTERACTIVE" "zsh wrapper should keep the opencode session attached to the terminal"
  assert_opencode_log_count "$opencode_log" 2 "zsh wrapper wt new should launch opencode after branch generation"
  assert_opencode_log_invocation_contains "$opencode_log" 1 "zsh wrapper wt new should launch opencode in the new worktree" "$expected" "--agent" "Build" "--prompt" "add a guided onboarding flow"
}

test_cd_missing_target_fails() {
  local repo
  repo=$(make_repo)

  if (cd "$repo" && bash "$ROOT/bin/wt" cd does-not-exist >/dev/null 2>&1); then
    fail "wt cd should fail for a missing target"
  fi
}

test_wrapper_rm_without_args_removes_current_worktree_and_branch() {
  local repo worktree output expected_repo
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  expected_repo=$(cd "$repo" && pwd -P)

  output=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$worktree"
wt rm >/dev/null
printf 'cwd=%s\n' "\$(pwd -P)"
if git -C "$repo" show-ref --verify --quiet refs/heads/feature/test; then
  printf 'branch=yes\n'
else
  printf 'branch=no\n'
fi
EOF
)

  assert_contains "$output" "cwd=$expected_repo" "wrapper wt rm without args should move back to the primary worktree"
  assert_contains "$output" "branch=no" "wrapper wt rm without args should delete the clean branch"
  assert_file_missing "$worktree" "wrapper wt rm without args should remove the current worktree"
}

test_wrapper_rm_without_args_refuses_on_main() {
  local repo output main_out main_err expected_repo
  repo=$(make_repo)
  expected_repo=$(cd "$repo" && pwd -P)
  main_out=$(mktemp)
  main_err=$(mktemp)

  output=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$repo"
if wt rm >"$main_out" 2>"$main_err"; then
  printf 'status=success\n'
else
  printf 'status=failure\n'
fi
printf 'cwd=%s\n' "\$(pwd -P)"
cat "$main_err"
EOF
)

  rm -f "$main_out" "$main_err"

  assert_contains "$output" "status=failure" "wt rm without args should fail on the primary worktree"
  assert_contains "$output" "cwd=$expected_repo" "failed wt rm on the primary worktree should keep the shell in place"
  assert_contains "$output" "Refusing to remove the primary worktree" "wt rm without args should explain the primary-worktree refusal"
}

test_wrapper_rm_without_args_dirty_keeps_current_directory() {
  local repo worktree output dirty_out dirty_err expected_worktree
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  touch "$worktree/dirty.txt"
  expected_worktree=$(cd "$worktree" && pwd -P)
  dirty_out=$(mktemp)
  dirty_err=$(mktemp)

  output=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$worktree"
if wt rm >"$dirty_out" 2>"$dirty_err"; then
  printf 'status=success\n'
else
  printf 'status=failure\n'
fi
printf 'cwd=%s\n' "\$(pwd -P)"
cat "$dirty_err"
EOF
)

  rm -f "$dirty_out" "$dirty_err"

  assert_contains "$output" "status=failure" "dirty wt rm without args should fail"
  assert_contains "$output" "cwd=$expected_worktree" "dirty wt rm without args should not switch away before failing"
  assert_contains "$output" "Refusing to remove a dirty worktree without --force" "dirty wt rm without args should explain the refusal"
  assert_file_exists "$worktree" "dirty wt rm without args should keep the worktree"
}

test_wrapper_rm_force_without_args_removes_dirty_current_worktree_and_branch() {
  local repo worktree output expected_repo
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  touch "$worktree/dirty.txt"
  expected_repo=$(cd "$repo" && pwd -P)

  output=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$worktree"
wt rm --force >/dev/null
printf 'cwd=%s\n' "\$(pwd -P)"
if git -C "$repo" show-ref --verify --quiet refs/heads/feature/test; then
  printf 'branch=yes\n'
else
  printf 'branch=no\n'
fi
EOF
)

  assert_contains "$output" "cwd=$expected_repo" "wrapper wt rm --force without args should move back to the primary worktree"
  assert_contains "$output" "branch=no" "wrapper wt rm --force without args should force delete the branch"
  assert_file_missing "$worktree" "wrapper wt rm --force without args should remove the dirty worktree"
}

test_wrapper_rm_without_args_works_from_non_main_primary_branch() {
  local repo worktree output expected_repo
  repo=$(make_repo trunk)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  expected_repo=$(cd "$repo" && pwd -P)

  output=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$worktree"
wt rm >/dev/null
printf 'cwd=%s\n' "\$(pwd -P)"
if git -C "$repo" show-ref --verify --quiet refs/heads/feature/test; then
  printf 'branch=yes\n'
else
  printf 'branch=no\n'
fi
EOF
)

  assert_contains "$output" "cwd=$expected_repo" "wrapper wt rm without args should return to the primary worktree even when the branch is not named main"
  assert_contains "$output" "branch=no" "wrapper wt rm without args should delete the clean branch on a non-main primary branch"
  assert_file_missing "$worktree" "wrapper wt rm without args should remove the current worktree on a non-main primary branch"
}

test_rm_explicit_target_deletes_clean_branch() {
  local repo worktree output expected_worktree
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  expected_worktree=$(cd "$worktree" && pwd -P)

  output=$(cd "$repo" && bash "$ROOT/bin/wt" rm feature/test)

  assert_contains "$output" "Remove" "wt rm should print a remove section before deleting a worktree"
  assert_contains "$output" "Removed" "wt rm should print a removed section after deleting a worktree"
  assert_contains "$output" "removed_worktree: $expected_worktree" "wt rm should report the removed worktree path"
  assert_contains "$output" "removed_branch: feature/test" "wt rm should report the removed branch name"
  assert_file_missing "$worktree" "wt rm with an explicit clean target should remove the worktree"
  if git -C "$repo" show-ref --verify --quiet refs/heads/feature/test; then
    fail "wt rm with an explicit clean target should delete the branch"
  fi
}

test_rm_explicit_target_dims_subprocess_output_in_pty() {
  local repo worktree output rendered_output
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  output=$(cd "$repo" && run_in_pty '' bash "$ROOT/bin/wt" rm feature/test)
  rendered_output=$(render_terminal_output "$output")

  assert_contains "$output" $'\033[2mDeleted branch feature/test' "wt rm should dim raw subprocess output in a PTY"
  assert_contains "$rendered_output" "Deleted branch feature/test" "wt rm should still show the git subprocess output text"
}

test_rm_explicit_target_leaves_unmerged_branch_when_branch_delete_fails() {
  local repo worktree output
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  printf 'feature\n' >"$worktree/feature.txt"
  commit_repo_state "$worktree" "feature commit"

  if output=$(cd "$repo" && bash "$ROOT/bin/wt" rm feature/test 2>&1 >/dev/null); then
    fail "wt rm should fail when branch deletion with -d fails"
  fi

  assert_file_missing "$worktree" "wt rm should still remove the worktree before branch deletion fails"
  if ! git -C "$repo" show-ref --verify --quiet refs/heads/feature/test; then
    fail "wt rm should retain the unmerged branch when git branch -d fails"
  fi
  assert_contains "$output" "Removed worktree but failed to delete branch with git branch -d: feature/test" "wt rm should explain partial branch deletion failure"
}

test_help_includes_status_prune_diff() {
  local output

  output=$(bash "$ROOT/bin/wt" --help)

  assert_contains "$output" "wt status [branch-or-handle]" "wt help should include the status command"
  assert_contains "$output" "wt diff [branch-or-handle]" "wt help should include the diff command"
  assert_contains "$output" "wt prune [--dry-run]" "wt help should include the prune command"
}

test_status_reports_linked_worktree_relation() {
  local repo worktree output
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature\n' >"$worktree/feature.txt"
  commit_repo_state "$worktree" "feature commit"

  printf 'primary\n' >"$repo/primary.txt"
  commit_repo_state "$repo" "primary commit"

  output=$(cd "$worktree" && bash "$ROOT/bin/wt" status)

  assert_contains "$output" "Status" "wt status should print a dedicated status section"
  assert_contains "$output" "primary_ref: main" "wt status should report the current primary branch"
  assert_contains "$output" "ahead_of_primary: 1" "wt status should report feature commits ahead of primary"
  assert_contains "$output" "behind_primary: 1" "wt status should report primary commits not yet synced"
  assert_contains "$output" "sync_status: merge-required" "wt status should describe a non-fast-forward sync"
  assert_contains "$output" "merge_status: reverse-merge-required" "wt status should describe a non-fast-forward merge"
}

test_status_reports_primary_stale_worktree_counts() {
  local repo worktree output
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  rm -rf "$worktree"

  output=$(cd "$repo" && bash "$ROOT/bin/wt" status)

  assert_contains "$output" "type: primary" "wt status on the main checkout should mark it as primary"
  assert_contains "$output" "linked_worktrees: 1" "wt status should count linked worktrees from the primary checkout"
  assert_contains "$output" "stale_worktrees: 1" "wt status should count stale linked worktrees from the primary checkout"
}

test_status_uses_current_primary_branch_when_primary_switches() {
  local repo worktree output primary_branch
  repo=$(make_repo trunk)
  git -C "$repo" switch -c release/1.0 >/dev/null
  primary_branch=$(repo_primary_branch "$repo")
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature\n' >"$worktree/feature.txt"
  commit_repo_state "$worktree" "feature commit"

  printf 'release\n' >"$repo/release.txt"
  commit_repo_state "$repo" "release commit"

  output=$(cd "$worktree" && bash "$ROOT/bin/wt" status)

  assert_eq "release/1.0" "$primary_branch" "test setup should switch the primary worktree to a non-default branch"
  assert_contains "$output" "primary_ref: release/1.0" "wt status should follow the currently checked out primary branch"
}

test_prune_noops_when_no_stale_entries_exist() {
  local repo worktree output worktree_list
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  output=$(cd "$repo" && bash "$ROOT/bin/wt" prune)
  worktree_list=$(git -C "$repo" worktree list --porcelain)

  assert_contains "$output" "Prune" "wt prune should print a dedicated prune section"
  assert_contains "$output" "prune: nothing to do" "wt prune should report when there is no stale metadata to clean"
  assert_contains "$worktree_list" "$worktree" "wt prune should leave live worktrees alone"
}

test_prune_dry_run_keeps_stale_worktree_metadata() {
  local repo worktree output worktree_list
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  rm -rf "$worktree"

  output=$(cd "$repo" && bash "$ROOT/bin/wt" prune --dry-run)
  worktree_list=$(git -C "$repo" worktree list --porcelain)

  assert_contains "$output" "dry_run: true" "wt prune --dry-run should report dry-run mode"
  assert_contains "$output" "stale_worktrees: 1" "wt prune --dry-run should report stale entries"
  assert_contains "$worktree_list" "$worktree" "wt prune --dry-run should keep stale metadata intact"
}

test_prune_removes_prunable_worktree_metadata_only() {
  local repo stale_worktree keep_worktree output worktree_list
  repo=$(make_repo)
  stale_worktree="${repo}__worktrees/feature-test"
  keep_worktree="${repo}__worktrees/feature-keep"
  git -C "$repo" worktree add "$stale_worktree" -b feature/test >/dev/null
  git -C "$repo" worktree add "$keep_worktree" -b feature/keep >/dev/null
  rm -rf "$stale_worktree"

  output=$(cd "$repo" && bash "$ROOT/bin/wt" prune)
  worktree_list=$(git -C "$repo" worktree list --porcelain)

  assert_contains "$output" "Pruned" "wt prune should print a completion section after cleaning stale metadata"
  assert_contains "$output" "pruned_worktrees: 1" "wt prune should report how many stale worktrees it removed"
  assert_not_contains "$worktree_list" "$stale_worktree" "wt prune should remove stale worktree metadata"
  assert_contains "$worktree_list" "$keep_worktree" "wt prune should leave live worktrees registered"
  if ! git -C "$repo" show-ref --verify --quiet refs/heads/feature/test; then
    fail "wt prune should not delete the stale branch ref"
  fi
}

test_prune_skips_locked_stale_worktree() {
  local repo worktree output worktree_list
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  git -C "$repo" worktree lock "$worktree" >/dev/null
  rm -rf "$worktree"

  output=$(cd "$repo" && bash "$ROOT/bin/wt" prune)
  worktree_list=$(git -C "$repo" worktree list --porcelain)

  assert_contains "$output" "prune: nothing to do" "wt prune should not attempt locked stale worktrees"
  assert_contains "$output" "skipped_locked: 1" "wt prune should report locked stale worktrees separately"
  assert_contains "$worktree_list" "$worktree" "wt prune should leave locked stale worktree metadata in place"
}

test_diff_pins_feature_vs_primary_direction() {
  local repo worktree output
  repo=$(make_repo)
  printf 'base\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "add base"
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'primary\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "primary commit"

  printf 'feature\n' >"$worktree/shared.txt"
  commit_repo_state "$worktree" "feature commit"

  output=$(cd "$worktree" && bash "$ROOT/bin/wt" diff)

  assert_contains "$output" "Diff" "wt diff should print a dedicated diff section"
  assert_contains "$output" "Commits" "wt diff should list target-only commits when they exist"
  assert_contains "$output" "Patch" "wt diff should print a dedicated patch section"
  assert_contains "$output" "+feature" "wt diff should show the feature-side change"
  assert_not_contains "$output" "+primary" "wt diff should compare feature changes against the merge base, not primary-only lines"
}

test_diff_refuses_dirty_worktree() {
  local repo worktree output
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  touch "$worktree/dirty.txt"

  if output=$(cd "$worktree" && bash "$ROOT/bin/wt" diff 2>&1); then
    fail "wt diff should refuse a dirty worktree"
  fi

  assert_contains "$output" "Cannot diff: worktree has uncommitted changes" "wt diff should explain the dirty-worktree refusal"
}

test_diff_uses_current_primary_branch_when_primary_switches() {
  local repo worktree output primary_branch
  repo=$(make_repo trunk)
  git -C "$repo" switch -c release/1.0 >/dev/null
  primary_branch=$(repo_primary_branch "$repo")
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature\n' >"$worktree/feature.txt"
  commit_repo_state "$worktree" "feature commit"

  output=$(cd "$worktree" && bash "$ROOT/bin/wt" diff)

  assert_eq "release/1.0" "$primary_branch" "test setup should switch the primary worktree to a non-default branch"
  assert_contains "$output" "primary_ref: release/1.0" "wt diff should follow the currently checked out primary branch"
}

test_ls_shows_branch_first() {
  local repo output header
  repo=$(make_repo)
  git -C "$repo" worktree add "${repo}__worktrees/feature-test" -b feature/test >/dev/null

  output=$(cd "$repo" && bash "$ROOT/bin/wt" ls)
  header=$(printf '%s\n' "$output" | /usr/bin/awk 'NR==1 { print $1 " " $2 " " $3 " " $4 }')
  assert_eq "BRANCH HANDLE TYPE STATE" "$header" "wt ls should show branch first"
}

test_ls_marks_primary_worktree_as_primary() {
  local repo output primary_branch primary_row
  repo=$(make_repo trunk)
  primary_branch=$(repo_primary_branch "$repo")

  output=$(cd "$repo" && bash "$ROOT/bin/wt" ls)
  primary_row=$(printf '%s\n' "$output" | /usr/bin/awk 'NR==2 { print }')

  assert_contains "$primary_row" "$primary_branch" "wt ls should show the primary branch in the first row"
  assert_contains "$primary_row" "primary" "wt ls should mark the primary checkout as primary"
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
  local repo fake_bin chrome_bin devtools_bin browser_log devtools_log browser_pids debug_port user_data_dir log_line
  repo=$(make_repo)
  write_portless_package_json "$repo" "guidance-studio" "portless run --name guidance env -u HOST nuxt dev"
  fake_bin=$(make_fake_portless_bin)
  chrome_bin=$(make_fake_browser_bin)
  devtools_bin=$(make_fake_devtools_bin)
  browser_log=$(mktemp)
  devtools_log=$(mktemp)
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
    WT_TEST_DEVTOOLS_LOG="$devtools_log" \
    WT_TEST_DEVTOOLS_READY_DELAY=0.2 \
    WT_TEST_FAKE_DEVTOOLS_BIN="$devtools_bin" \
    WT_TEST_BROWSER_AUTOLISTEN=1 \
    WT_TEST_BROWSER_PIDS="$browser_pids" \
    bash "$ROOT/bin/wt" b >/dev/null
  )

  log_line=$(cat "$browser_log")
  assert_contains "$log_line" "--remote-debugging-port=$debug_port" "wt b should launch Chrome with the fixed debug port"
  assert_contains "$log_line" "--user-data-dir=$user_data_dir" "wt b should launch Chrome with the configured userDataDir"
  assert_not_contains "$log_line" "https://guidance.localhost:1355" "wt b should not pass the target URL on the initial Chrome launch"
  assert_contains "$(cat "$devtools_log")" $'\thttps://guidance.localhost:1355' "wt b should open the current worktree URL through DevTools"
  cleanup_pids_file "$browser_pids"
}

test_b_reuses_debug_browser_for_requested_worktree() {
  local repo fake_bin chrome_bin devtools_bin browser_log devtools_log debug_port server_pid
  repo=$(make_repo)
  write_portless_package_json "$repo" "guidance-studio" "portless myapp pnpm dev"
  commit_repo_state "$repo" "add package"
  git -C "$repo" worktree add "${repo}__worktrees/feature-test" -b feature/test >/dev/null
  fake_bin=$(make_fake_portless_bin)
  chrome_bin=$(make_fake_browser_bin)
  devtools_bin=$(make_fake_devtools_bin)
  browser_log=$(mktemp)
  devtools_log=$(mktemp)
  debug_port=$(free_port)
  WT_TEST_DEVTOOLS_LOG="$devtools_log" "$devtools_bin" "$debug_port" >/dev/null 2>&1 &
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
  assert_eq "" "$(cat "$browser_log")" "wt b should not relaunch Chrome when a reusable debug browser already exists"
  assert_contains "$(cat "$devtools_log")" $'\thttps://feature-test.myapp.localhost:1355' "wt b should open the requested worktree URL through DevTools reuse"
}

test_b_uses_cli_section_output() {
  local repo fake_bin chrome_bin devtools_bin browser_log devtools_log debug_port user_data_dir browser_pids output
  repo=$(make_repo)
  write_portless_package_json "$repo" "guidance-studio" "portless myapp pnpm dev"
  commit_repo_state "$repo" "add package"
  fake_bin=$(make_fake_portless_bin)
  chrome_bin=$(make_fake_browser_bin)
  devtools_bin=$(make_fake_devtools_bin)
  browser_log=$(mktemp)
  devtools_log=$(mktemp)
  browser_pids=$(mktemp)
  debug_port=$(free_port)
  user_data_dir=$(mktemp -d)

  output=$(
    cd "$repo" && \
    PATH="$fake_bin:$PATH" \
    WT_CHROME_BIN="$chrome_bin" \
    WT_DEBUG_PORT="$debug_port" \
    WT_DEBUG_USER_DATA_DIR="$user_data_dir" \
    WT_TEST_BROWSER_LOG="$browser_log" \
    WT_TEST_DEVTOOLS_LOG="$devtools_log" \
    WT_TEST_DEVTOOLS_READY_DELAY=0.2 \
    WT_TEST_FAKE_DEVTOOLS_BIN="$devtools_bin" \
    WT_TEST_BROWSER_AUTOLISTEN=1 \
    WT_TEST_BROWSER_PIDS="$browser_pids" \
    bash "$ROOT/bin/wt" b
  )

  assert_contains "$output" "Browser" "wt b should print a browser section"
  assert_contains "$output" "browser: started" "wt b should report the browser launch outcome"
  assert_contains "$output" "debug_url: https://myapp.localhost:1355" "wt b should report the debug url in structured output"
  cleanup_pids_file "$browser_pids"
}

test_b_rejects_non_devtools_listener_on_debug_port() {
  local repo fake_bin chrome_bin browser_log debug_port server_pid output
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

  if output=$(
    cd "$repo" && \
    PATH="$fake_bin:$PATH" \
    WT_CHROME_BIN="$chrome_bin" \
    WT_DEBUG_PORT="$debug_port" \
    WT_TEST_BROWSER_LOG="$browser_log" \
    bash "$ROOT/bin/wt" b feature/test 2>&1 >/dev/null
  ); then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
    fail "wt b should fail when the debug port is occupied by a non-DevTools listener"
  fi

  sleep 0.2
  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true
  assert_contains "$output" "Debug port $debug_port is already in use by a non-reusable service" "wt b should explain why a non-DevTools listener cannot be reused"
  assert_eq "" "$(cat "$browser_log")" "wt b should not launch Chrome when the debug port is occupied by a non-DevTools listener"
}

configure_repo_for_merge() {
  local repo
  repo=$1
  git -C "$repo" config user.name "wt"
  git -C "$repo" config user.email "wt@example.com"
  git -C "$repo" config commit.gpgsign "false"
}

repo_primary_branch() {
  local repo
  repo=$1
  git -C "$repo" branch --show-current
}

repo_dirty_state() {
  local repo status_output
  repo=$1
  status_output=$(git -C "$repo" status --porcelain --untracked-files=normal 2>/dev/null || true)
  if [ -n "$status_output" ]; then
    printf '%s\n' "dirty"
  else
    printf '%s\n' "clean"
  fi
}

test_merge_fast_forward() {
  local repo worktree output expected_repo
  repo=$(make_repo)
  configure_repo_for_merge "$repo"
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature\n' >"$worktree/feature.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add feature.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "add feature" >/dev/null

  expected_repo=$(cd "$repo" && pwd -P)

  output=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$worktree"
wt merge
printf 'cwd=%s\n' "\$(pwd -P)"
EOF
)

  assert_contains "$output" "Merge" "wt merge should print a dedicated merge section"
  assert_contains "$output" "Removed" "wt merge should print a removed section after cleanup"
  assert_contains "$output" "merge: fast-forward" "wt merge should report fast-forward"
  assert_contains "$output" "removed_worktree:" "wt merge should remove the worktree"
  assert_contains "$output" "removed_branch: feature/test" "wt merge should delete the branch"
  assert_contains "$output" "cwd=$expected_repo" "wt merge wrapper should cd to the primary worktree"
  assert_file_missing "$worktree" "wt merge should remove the worktree directory"
}

test_merge_non_ff_clean() {
  local repo worktree output expected_repo primary_branch
  repo=$(make_repo)
  configure_repo_for_merge "$repo"
  primary_branch=$(repo_primary_branch "$repo")
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature\n' >"$worktree/feature.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add feature.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "add feature" >/dev/null

  printf 'primary change\n' >"$repo/primary.txt"
  commit_repo_state "$repo" "add primary change"

  expected_repo=$(cd "$repo" && pwd -P)

  output=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$worktree"
wt merge
printf 'cwd=%s\n' "\$(pwd -P)"
EOF
)

  assert_contains "$output" "Merge" "wt merge should print a dedicated merge section"
  assert_contains "$output" "Removed" "wt merge should print a removed section after cleanup"
  assert_contains "$output" "merge: resolved without conflicts" "wt merge should report clean reverse merge"
  assert_contains "$output" "merge: primary updated" "wt merge should report primary updated"
  assert_contains "$output" "removed_worktree:" "wt merge should remove the worktree"
  assert_contains "$output" "removed_branch: feature/test" "wt merge should delete the branch"
  assert_contains "$output" "cwd=$expected_repo" "wt merge wrapper should cd to the primary worktree"
  assert_file_missing "$worktree" "wt merge should remove the worktree directory"
  assert_file_exists "$repo/feature.txt" "the primary branch should contain the feature file after merge"
  assert_file_exists "$repo/primary.txt" "the primary branch should retain its own file after merge"
}

test_merge_refuses_dirty_worktree() {
  local repo worktree output
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  touch "$worktree/dirty.txt"

  if output=$(cd "$worktree" && bash "$ROOT/bin/wt" merge 2>&1); then
    fail "wt merge should refuse a dirty worktree"
  fi

  assert_contains "$output" "Cannot merge: worktree has uncommitted changes" "wt merge should explain the dirty refusal"
}

test_merge_refuses_no_commits_ahead() {
  local repo worktree output primary_branch
  repo=$(make_repo)
  primary_branch=$(repo_primary_branch "$repo")
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  if output=$(cd "$worktree" && bash "$ROOT/bin/wt" merge 2>&1); then
    fail "wt merge should refuse when no commits ahead"
  fi

  assert_contains "$output" "Cannot merge: no commits ahead of $primary_branch" "wt merge should explain the no-commits refusal"
}

test_merge_refuses_primary_worktree() {
  local repo output
  repo=$(make_repo)

  if output=$(cd "$repo" && bash "$ROOT/bin/wt" merge 2>&1); then
    fail "wt merge should refuse on the primary worktree"
  fi

  assert_contains "$output" "Cannot merge: already on the primary worktree" "wt merge should explain the primary-worktree refusal"
}

test_merge_uses_current_primary_branch_when_primary_switches() {
  local repo worktree output expected_repo primary_branch
  repo=$(make_repo trunk)
  configure_repo_for_merge "$repo"
  git -C "$repo" switch -c release/1.0 >/dev/null
  primary_branch=$(repo_primary_branch "$repo")
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature\n' >"$worktree/feature.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add feature.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "add feature" >/dev/null

  printf 'release change\n' >"$repo/release.txt"
  commit_repo_state "$repo" "add release change"

  expected_repo=$(cd "$repo" && pwd -P)

  output=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$worktree"
wt merge
printf 'cwd=%s\n' "\$(pwd -P)"
EOF
)

  assert_eq "release/1.0" "$primary_branch" "test setup should switch the primary worktree to a different branch"
  assert_contains "$output" "merge: primary updated" "wt merge should update the currently checked out primary branch"
  assert_contains "$output" "cwd=$expected_repo" "wt merge wrapper should return to the current primary worktree"
  assert_file_exists "$repo/feature.txt" "the switched primary branch should receive the feature commit"
  assert_file_exists "$repo/release.txt" "the switched primary branch should keep its own commit"
}

test_merge_refuses_when_primary_worktree_is_detached_head() {
  local repo worktree output
  repo=$(make_repo)
  configure_repo_for_merge "$repo"
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature\n' >"$worktree/feature.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add feature.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "add feature" >/dev/null

  git -C "$repo" checkout --detach >/dev/null 2>&1

  if output=$(cd "$worktree" && bash "$ROOT/bin/wt" merge 2>&1); then
    fail "wt merge should refuse when the primary worktree is detached"
  fi

  assert_contains "$output" "Unable to determine the primary branch" "wt merge should explain why detached primary HEAD is unsupported"
}

test_merge_with_conflicts_ai_resolves() {
  local repo worktree fake_bin opencode_log output prompt_log resolved_contents
  repo=$(make_repo)
  configure_repo_for_merge "$repo"

  printf 'original\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "add shared file"

  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature change\n' >"$worktree/shared.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add shared.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "feature change to shared" >/dev/null

  printf 'primary change\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "primary change to shared"

  fake_bin=$(make_fake_opencode_merge_bin)
  opencode_log=$(mktemp)

  output=$(cd "$worktree" && WT_TEST_OPENCODE_LOG="$opencode_log" PATH="$fake_bin:$PATH" bash "$ROOT/bin/wt" merge 2>&1)
  prompt_log=$(cat "$opencode_log")
  resolved_contents=$(cat "$repo/shared.txt")

  assert_contains "$output" "merge: conflicts detected" "wt merge should detect conflicts"
  assert_contains "$output" "merge: conflicts resolved by AI" "wt merge should report AI resolution"
  assert_contains "$prompt_log" "Prefer the current branch/worktree side as the default source of truth" "wt merge should tell Maat to prefer worktree-side changes"
  assert_contains "$prompt_log" "If any conflict is ambiguous, use the question tool instead of guessing" "wt merge should tell Maat to ask questions when uncertain"
  assert_contains "$output" "removed_worktree:" "wt merge should remove the worktree after AI resolution"
  assert_contains "$output" "removed_branch: feature/test" "wt merge should delete the branch after AI resolution"
  assert_file_missing "$worktree" "wt merge should remove the worktree directory after AI resolution"
  assert_file_exists "$repo/shared.txt" "the primary branch should contain the shared file after AI merge"
  assert_eq "feature change" "$resolved_contents" "wt merge should keep the worktree-side change when AI resolves a content conflict"
}

test_merge_with_conflicts_ai_fails() {
  local repo worktree fake_bin output
  repo=$(make_repo)
  configure_repo_for_merge "$repo"

  printf 'original\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "add shared file"

  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature change\n' >"$worktree/shared.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add shared.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "feature change to shared" >/dev/null

  printf 'primary change\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "primary change to shared"

  fake_bin=$(make_fake_opencode_noop_bin)

  if output=$(cd "$worktree" && PATH="$fake_bin:$PATH" bash "$ROOT/bin/wt" merge 2>&1); then
    fail "wt merge should fail when AI cannot resolve conflicts"
  fi

  assert_contains "$output" "merge: conflicts detected" "wt merge should detect conflicts"
  assert_contains "$output" "Merge aborted: conflicts were not fully resolved" "wt merge should report abort"
  assert_file_exists "$worktree" "wt merge should keep the worktree when AI fails"

  local worktree_state
  worktree_state=$(repo_dirty_state "$worktree")
  assert_eq "clean" "$worktree_state" "wt merge should abort the merge cleanly when AI fails"
}

test_merge_non_ff_clean_with_non_main_primary_branch() {
  local repo worktree output expected_repo primary_branch
  repo=$(make_repo trunk)
  configure_repo_for_merge "$repo"
  primary_branch=$(repo_primary_branch "$repo")
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature\n' >"$worktree/feature.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add feature.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "add feature" >/dev/null

  printf 'primary change\n' >"$repo/primary.txt"
  commit_repo_state "$repo" "add primary change"

  expected_repo=$(cd "$repo" && pwd -P)

  output=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$worktree"
wt merge
printf 'cwd=%s\n' "\$(pwd -P)"
EOF
)

  assert_eq "trunk" "$primary_branch" "test setup should use a non-main primary branch"
  assert_contains "$output" "merge: resolved without conflicts" "wt merge should report clean reverse merge on a non-main primary branch"
  assert_contains "$output" "merge: primary updated" "wt merge should report primary updated on a non-main primary branch"
  assert_contains "$output" "cwd=$expected_repo" "wt merge wrapper should cd to the non-main primary worktree"
  assert_file_missing "$worktree" "wt merge should remove the worktree directory on a non-main primary branch"
  assert_file_exists "$repo/feature.txt" "the non-main primary branch should contain the feature file after merge"
  assert_file_exists "$repo/primary.txt" "the non-main primary branch should retain its own file after merge"
}

test_sync_fast_forward_keeps_current_worktree() {
  local repo worktree output expected_worktree
  repo=$(make_repo)
  configure_repo_for_merge "$repo"
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'primary change\n' >"$repo/primary.txt"
  commit_repo_state "$repo" "add primary change"

  expected_worktree=$(cd "$worktree" && pwd -P)

  output=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash <<EOF
set -euo pipefail
source "$ROOT/shell/wt.bash"
cd "$worktree"
wt sync
printf 'cwd=%s\n' "\$(pwd -P)"
EOF
)

  assert_contains "$output" "Sync" "wt sync should print a dedicated sync section"
  assert_contains "$output" "sync: fast-forward" "wt sync should fast-forward when the current branch has no unique commits"
  assert_contains "$output" "cwd=$expected_worktree" "wt sync should keep the shell in the current worktree"
  assert_file_exists "$worktree/primary.txt" "wt sync should bring primary changes into the current worktree"
  assert_file_exists "$worktree" "wt sync should keep the worktree intact"
  if ! git -C "$repo" show-ref --verify --quiet refs/heads/feature/test; then
    fail "wt sync should keep the current branch after syncing"
  fi
}

test_sync_non_ff_clean() {
  local repo worktree output
  repo=$(make_repo)
  configure_repo_for_merge "$repo"
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature\n' >"$worktree/feature.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add feature.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "add feature" >/dev/null

  printf 'primary change\n' >"$repo/primary.txt"
  commit_repo_state "$repo" "add primary change"

  output=$(cd "$worktree" && bash "$ROOT/bin/wt" sync)

  assert_contains "$output" "Sync" "wt sync should print a dedicated sync section"
  assert_contains "$output" "sync: resolved without conflicts" "wt sync should report a clean merge when both branches moved"
  assert_file_exists "$worktree/feature.txt" "wt sync should retain the current branch changes"
  assert_file_exists "$worktree/primary.txt" "wt sync should merge in the primary branch changes"
  assert_file_exists "$worktree" "wt sync should keep the worktree directory"
}

test_sync_refuses_dirty_worktree() {
  local repo worktree output
  repo=$(make_repo)
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null
  touch "$worktree/dirty.txt"

  if output=$(cd "$worktree" && bash "$ROOT/bin/wt" sync 2>&1); then
    fail "wt sync should refuse a dirty worktree"
  fi

  assert_contains "$output" "Cannot sync: worktree has uncommitted changes" "wt sync should explain the dirty refusal"
}

test_sync_refuses_no_commits_ahead() {
  local repo worktree output primary_branch
  repo=$(make_repo)
  primary_branch=$(repo_primary_branch "$repo")
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  if output=$(cd "$worktree" && bash "$ROOT/bin/wt" sync 2>&1); then
    fail "wt sync should refuse when the primary branch has no commits ahead"
  fi

  assert_contains "$output" "Cannot sync: no commits ahead on $primary_branch" "wt sync should explain the no-op refusal"
}

test_sync_refuses_primary_worktree() {
  local repo output
  repo=$(make_repo)

  if output=$(cd "$repo" && bash "$ROOT/bin/wt" sync 2>&1); then
    fail "wt sync should refuse on the primary worktree"
  fi

  assert_contains "$output" "Cannot sync: already on the primary worktree" "wt sync should explain the primary-worktree refusal"
}

test_sync_uses_current_primary_branch_when_primary_switches() {
  local repo worktree output primary_branch
  repo=$(make_repo trunk)
  configure_repo_for_merge "$repo"
  git -C "$repo" switch -c release/1.0 >/dev/null
  primary_branch=$(repo_primary_branch "$repo")
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature\n' >"$worktree/feature.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add feature.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "add feature" >/dev/null

  printf 'release change\n' >"$repo/release.txt"
  commit_repo_state "$repo" "add release change"

  output=$(cd "$worktree" && bash "$ROOT/bin/wt" sync)

  assert_eq "release/1.0" "$primary_branch" "test setup should switch the primary worktree to a different branch"
  assert_contains "$output" "sync: resolved without conflicts" "wt sync should merge from the currently checked out primary branch"
  assert_file_exists "$worktree/release.txt" "wt sync should bring in commits from the switched primary branch"
  assert_file_exists "$worktree/feature.txt" "wt sync should retain current branch changes when primary is switched"
}

test_sync_refuses_when_primary_worktree_is_detached_head() {
  local repo worktree output
  repo=$(make_repo)
  configure_repo_for_merge "$repo"
  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature\n' >"$worktree/feature.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add feature.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "add feature" >/dev/null

  git -C "$repo" checkout --detach >/dev/null 2>&1

  if output=$(cd "$worktree" && bash "$ROOT/bin/wt" sync 2>&1); then
    fail "wt sync should refuse when the primary worktree is detached"
  fi

  assert_contains "$output" "Unable to determine the primary branch" "wt sync should explain why detached primary HEAD is unsupported"
}

test_sync_with_conflicts_ai_resolves() {
  local repo worktree fake_bin opencode_log output prompt_log resolved_contents
  repo=$(make_repo)
  configure_repo_for_merge "$repo"

  printf 'original\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "add shared file"

  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature change\n' >"$worktree/shared.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add shared.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "feature change to shared" >/dev/null

  printf 'primary change\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "primary change to shared"

  fake_bin=$(make_fake_opencode_merge_bin)
  opencode_log=$(mktemp)

  output=$(cd "$worktree" && WT_TEST_OPENCODE_LOG="$opencode_log" PATH="$fake_bin:$PATH" bash "$ROOT/bin/wt" sync 2>&1)
  prompt_log=$(cat "$opencode_log")
  resolved_contents=$(cat "$worktree/shared.txt")

  assert_contains "$output" "sync: conflicts detected" "wt sync should detect conflicts"
  assert_contains "$output" "sync: conflicts resolved by AI" "wt sync should report AI resolution"
  assert_contains "$prompt_log" "Prefer the current branch/worktree side as the default source of truth" "wt sync should tell Maat to prefer worktree-side changes"
  assert_contains "$prompt_log" "If any conflict is ambiguous, use the question tool instead of guessing" "wt sync should tell Maat to ask questions when uncertain"
  assert_file_exists "$worktree/shared.txt" "wt sync should keep the worktree after resolving conflicts"
  assert_eq "feature change" "$resolved_contents" "wt sync should keep the worktree-side change when AI resolves a content conflict"
}

test_sync_with_conflicts_ai_fails() {
  local repo worktree fake_bin output
  repo=$(make_repo)
  configure_repo_for_merge "$repo"

  printf 'original\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "add shared file"

  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature change\n' >"$worktree/shared.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add shared.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "feature change to shared" >/dev/null

  printf 'primary change\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "primary change to shared"

  fake_bin=$(make_fake_opencode_noop_bin)

  if output=$(cd "$worktree" && PATH="$fake_bin:$PATH" bash "$ROOT/bin/wt" sync 2>&1); then
    fail "wt sync should fail when AI cannot resolve conflicts"
  fi

  assert_contains "$output" "sync: conflicts detected" "wt sync should detect conflicts"
  assert_contains "$output" "Sync aborted: conflicts were not fully resolved" "wt sync should report abort"
  assert_file_exists "$worktree" "wt sync should keep the worktree when AI fails"

  local worktree_state
  worktree_state=$(repo_dirty_state "$worktree")
  assert_eq "clean" "$worktree_state" "wt sync should abort the merge cleanly when AI fails"
}

test_sync_with_conflicts_missing_opencode_aborts_cleanly() {
  local repo worktree output worktree_state
  repo=$(make_repo)
  configure_repo_for_merge "$repo"

  printf 'original\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "add shared file"

  worktree="${repo}__worktrees/feature-test"
  git -C "$repo" worktree add "$worktree" -b feature/test >/dev/null

  printf 'feature change\n' >"$worktree/shared.txt"
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false add shared.txt >/dev/null
  git -C "$worktree" -c user.name=wt -c user.email=wt@example.com -c commit.gpgsign=false commit -m "feature change to shared" >/dev/null

  printf 'primary change\n' >"$repo/shared.txt"
  commit_repo_state "$repo" "primary change to shared"

  if output=$(cd "$worktree" && PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$ROOT/bin/wt" sync 2>&1); then
    fail "wt sync should fail when opencode is unavailable during conflict resolution"
  fi

  assert_contains "$output" "sync: conflicts detected" "wt sync should detect conflicts before requiring opencode"
  assert_contains "$output" "Sync aborted: missing required command: opencode" "wt sync should explain the missing opencode abort"
  worktree_state=$(repo_dirty_state "$worktree")
  assert_eq "clean" "$worktree_state" "wt sync should abort cleanly when opencode is unavailable"
}

test_new_runs_init_for_portless_worktree() {
  local repo fake_bin output expected_worktree
  repo=$(make_repo)
  write_portless_package_json "$repo" "guidance-studio" "portless run --name guidance env -u HOST nuxt dev"
  commit_repo_state "$repo" "add package"
  fake_bin=$(make_fake_portless_bin)

  output=$(cd "$repo" && PATH="$fake_bin:$PATH" bash "$ROOT/bin/wt" new feature/test 2>&1)
  expected_worktree=$(cd "${repo}__worktrees/feature-test" && pwd -P)

  assert_launch_json "${repo}__worktrees/feature-test/.vscode/launch.json" "https://feature-test.guidance.localhost:1355" "9222"
  assert_contains "$output" "Bootstrap" "wt new should keep bootstrap output grouped after worktree creation"
  assert_contains "$output" "launch_json: $expected_worktree/.vscode/launch.json" "wt new should include the generated launch.json path in the bootstrap section"
  assert_not_contains "$output" "debug_port:" "wt new should not print the debug port in the bootstrap section"
}

test_init_uses_cli_sections() {
  local repo fake_bin output
  repo=$(make_repo)
  write_portless_package_json "$repo" "guidance-studio" "portless run --name guidance env -u HOST nuxt dev"
  commit_repo_state "$repo" "add package"
  fake_bin=$(make_fake_portless_bin)

  output=$(cd "$repo" && PATH="$fake_bin:$PATH" bash "$ROOT/bin/wt" init 2>&1)

  assert_contains "$output" "Debug config" "wt init should print a dedicated debug config section"
  assert_contains "$output" "launch_json: " "wt init should report the managed launch file path"
  assert_contains "$output" "debug_url: https://guidance.localhost:1355" "wt init should report the derived debug url"
}

test_cd_matches_open
test_wrapper_cd_changes_directory
test_wrapper_new_changes_directory
test_new_without_args_accepts_opencode_suggestion
test_new_without_args_honors_branch_name_model_override
test_new_without_args_allows_editing_suggestion
test_new_without_args_handles_multibyte_backspace_in_goal_prompt
test_new_without_args_keeps_goal_prompt_visible_after_excess_backspace
test_new_without_args_handles_multibyte_backspace_in_branch_prompt
test_new_without_args_keeps_branch_prompt_visible_after_excess_backspace
test_new_without_args_requires_interactive_terminal
test_new_without_args_launches_opencode_when_confirmed
test_new_without_args_skips_opencode_when_declined
test_new_without_args_repompts_for_invalid_launch_confirmation
test_new_without_args_launches_opencode_with_original_goal_after_branch_edit
test_new_with_explicit_branch_does_not_launch_opencode
test_new_with_explicit_branch_is_plain_when_not_in_pty
test_new_with_explicit_branch_uses_cli_styling_in_pty
test_new_reports_worktree_before_dependency_install
test_wrapper_new_reports_worktree_before_dependency_install
test_wrapper_new_with_explicit_branch_uses_cli_styling
test_new_copies_root_local_entries_for_worktree_bootstrap
test_wrapper_new_without_args_changes_directory
test_wrapper_new_without_args_launches_opencode_and_changes_directory
test_wrapper_cd_missing_target_keeps_shell_alive
test_zsh_wrapper_cd_changes_directory
test_zsh_wrapper_new_changes_directory
test_zsh_wrapper_new_without_args_changes_directory
test_zsh_wrapper_new_without_args_launches_opencode_and_changes_directory
test_cd_missing_target_fails
test_wrapper_rm_without_args_removes_current_worktree_and_branch
test_wrapper_rm_without_args_refuses_on_main
test_wrapper_rm_without_args_dirty_keeps_current_directory
test_wrapper_rm_force_without_args_removes_dirty_current_worktree_and_branch
test_wrapper_rm_without_args_works_from_non_main_primary_branch
test_rm_explicit_target_deletes_clean_branch
test_rm_explicit_target_dims_subprocess_output_in_pty
test_rm_explicit_target_leaves_unmerged_branch_when_branch_delete_fails
test_help_includes_status_prune_diff
test_status_reports_linked_worktree_relation
test_status_reports_primary_stale_worktree_counts
test_status_uses_current_primary_branch_when_primary_switches
test_prune_noops_when_no_stale_entries_exist
test_prune_dry_run_keeps_stale_worktree_metadata
test_prune_removes_prunable_worktree_metadata_only
test_prune_skips_locked_stale_worktree
test_diff_pins_feature_vs_primary_direction
test_diff_refuses_dirty_worktree
test_diff_uses_current_primary_branch_when_primary_switches
test_ls_shows_branch_first
test_ls_marks_primary_worktree_as_primary
test_init_creates_launch_json_for_explicit_portless_name
test_init_preserves_unrelated_configs_and_removes_browser_launch
test_init_derives_name_for_portless_run
test_b_starts_debug_browser_for_current_worktree
test_b_reuses_debug_browser_for_requested_worktree
test_b_uses_cli_section_output
test_b_rejects_non_devtools_listener_on_debug_port
test_new_runs_init_for_portless_worktree
test_init_uses_cli_sections
test_merge_fast_forward
test_merge_non_ff_clean
test_merge_refuses_dirty_worktree
test_merge_refuses_no_commits_ahead
test_merge_refuses_primary_worktree
test_merge_uses_current_primary_branch_when_primary_switches
test_merge_refuses_when_primary_worktree_is_detached_head
test_merge_with_conflicts_ai_resolves
test_merge_with_conflicts_ai_fails
test_merge_non_ff_clean_with_non_main_primary_branch
test_sync_fast_forward_keeps_current_worktree
test_sync_non_ff_clean
test_sync_refuses_dirty_worktree
test_sync_refuses_no_commits_ahead
test_sync_refuses_primary_worktree
test_sync_uses_current_primary_branch_when_primary_switches
test_sync_refuses_when_primary_worktree_is_detached_head
test_sync_with_conflicts_ai_resolves
test_sync_with_conflicts_ai_fails
test_sync_with_conflicts_missing_opencode_aborts_cleanly

printf 'smoke tests passed\n'
