update_launch_json() {
  local target_root url managed_name debug_port launch_path vscode_dir
  target_root=$1
  url=$2
  managed_name=$3
  debug_port=$4
  require_python3

  vscode_dir="$target_root/.vscode"
  launch_path="$vscode_dir/launch.json"
  mkdir -p "$vscode_dir"

  python3 - "$launch_path" "$url" "$managed_name" "$debug_port" <<'PY'
import json
import os
import sys

launch_path, url, managed_name, debug_port = sys.argv[1:5]
browser_launch_types = {"chrome", "msedge", "edge", "pwa-chrome", "pwa-msedge"}

if os.path.exists(launch_path):
    try:
        with open(launch_path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {launch_path}: {exc}")
else:
    data = {}

if not isinstance(data, dict):
    raise SystemExit(f"{launch_path} must contain a JSON object")

configs = data.get("configurations")
if configs is None:
    configs = []
if not isinstance(configs, list):
    raise SystemExit(f"{launch_path} must contain a configurations array")

managed = {
    "type": "chrome",
    "request": "attach",
    "name": managed_name,
    "address": "localhost",
    "port": int(debug_port),
    "urlFilter": f"{url}/*",
    "webRoot": "${workspaceFolder}",
    "resolveSourceMapLocations": [
        "${workspaceFolder}/**",
        "!**/node_modules/**",
    ],
    "internalConsoleOptions": "neverOpen",
    "presentation": {
        "group": "wt",
        "order": 1,
    },
}

new_configs = [managed]
for config in configs:
    if not isinstance(config, dict):
        new_configs.append(config)
        continue
    if config.get("name") == managed_name:
        continue
    if config.get("request") == "launch" and config.get("type") in browser_launch_types:
        continue
    new_configs.append(config)

data["version"] = data.get("version", "0.2.0")
data["configurations"] = new_configs

with open(launch_path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

initialize_worktree_debug_config() {
  local target_root url debug_port
  target_root=$1
  url=$(derive_portless_url "$target_root")
  debug_port=$(get_debug_port)
  update_launch_json "$target_root" "$url" "$WT_MANAGED_LAUNCH_NAME" "$debug_port"
  note "launch_json: $target_root/.vscode/launch.json"
  note "debug_url: $url"
  note "debug_port: $debug_port"
}

resolve_target_root_or_current() {
  if [ $# -eq 0 ]; then
    require_git_repo
    get_repo_root
    return 0
  fi

  [ $# -eq 1 ] || die "Expected zero or one branch-or-handle argument"
  require_git_repo
  resolve_worktree_target "$1"
  printf '%s\n' "${WT_PATHS[$WT_TARGET_INDEX]}"
}

debug_port_is_listening() {
  local port
  port=$1
  require_python3

  python3 - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.2)
try:
    sock.connect(("127.0.0.1", port))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}

wait_for_debug_port() {
  local port attempts
  port=$1
  attempts=${2:-40}
  while [ "$attempts" -gt 0 ]; do
    if debug_port_is_listening "$port"; then
      return 0
    fi
    sleep 0.1
    attempts=$((attempts - 1))
  done
  return 1
}

debug_browser_is_reusable() {
  local port
  port=$1
  require_python3

  python3 - "$port" <<'PY'
import json
import sys
import urllib.error
import urllib.request

port = int(sys.argv[1])
request = urllib.request.Request(f"http://127.0.0.1:{port}/json/version", method="GET")

try:
    with urllib.request.urlopen(request, timeout=0.3) as response:
        if response.status != 200:
            raise SystemExit(1)
        payload = json.load(response)
except (OSError, ValueError, urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError):
    raise SystemExit(1)

if not isinstance(payload, dict):
    raise SystemExit(1)

browser = payload.get("Browser")
socket_url = payload.get("webSocketDebuggerUrl")
if not isinstance(browser, str) or not browser.strip():
    raise SystemExit(1)
if not isinstance(socket_url, str) or not socket_url.strip():
    raise SystemExit(1)
PY
}

wait_for_debug_browser() {
  local port attempts
  port=$1
  attempts=${2:-40}
  while [ "$attempts" -gt 0 ]; do
    if debug_browser_is_reusable "$port"; then
      return 0
    fi
    sleep 0.1
    attempts=$((attempts - 1))
  done
  return 1
}

open_url_in_debug_browser() {
  local port url
  port=$1
  url=$2
  require_python3

  python3 - "$port" "$url" <<'PY'
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

port = int(sys.argv[1])
target_url = sys.argv[2]
encoded_url = urllib.parse.quote(target_url, safe="")
request_url = f"http://127.0.0.1:{port}/json/new?{encoded_url}"


def load_json(request: urllib.request.Request) -> dict:
    with urllib.request.urlopen(request, timeout=1) as response:
        if response.status != 200:
            raise RuntimeError(f"unexpected status: {response.status}")
        payload = json.load(response)
    if not isinstance(payload, dict):
        raise RuntimeError("unexpected payload")
    return payload


try:
    load_json(urllib.request.Request(request_url, method="PUT"))
except urllib.error.HTTPError as error:
    if error.code != 405:
        raise SystemExit(1)
    try:
        load_json(urllib.request.Request(request_url, method="GET"))
    except (OSError, RuntimeError, ValueError, urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError):
        raise SystemExit(1)
except (OSError, RuntimeError, ValueError, urllib.error.URLError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

resolve_chrome_binary() {
  local candidate
  if [ -n "${WT_CHROME_BIN-}" ]; then
    [ -x "$WT_CHROME_BIN" ] || die "WT_CHROME_BIN is not executable: $WT_CHROME_BIN"
    printf '%s\n' "$WT_CHROME_BIN"
    return 0
  fi

  for candidate in google-chrome google-chrome-stable chromium chromium-browser chrome; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done

  for candidate in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  die "Could not find a Chrome-compatible browser. Set WT_CHROME_BIN to override."
}

launch_debug_browser_for_url() {
  local url chrome_bin debug_port user_data_dir
  url=$1
  chrome_bin=$(resolve_chrome_binary)
  debug_port=$(get_debug_port)
  user_data_dir=$(get_debug_user_data_dir)
  mkdir -p "$user_data_dir"

  if debug_port_is_listening "$debug_port"; then
    if debug_browser_is_reusable "$debug_port" && open_url_in_debug_browser "$debug_port" "$url"; then
      note "browser: reused"
      return 0
    fi
    die "Debug port $debug_port is already in use by a non-reusable service. Free the port or set WT_DEBUG_PORT to another value."
  fi

  "$chrome_bin" \
    --remote-debugging-port="$debug_port" \
    --user-data-dir="$user_data_dir" \
    --no-first-run \
    --no-default-browser-check >/dev/null 2>&1 &

  if ! wait_for_debug_browser "$debug_port"; then
    die "Debug browser did not expose a reusable DevTools endpoint on port $debug_port. Ensure no other Chrome is already using $user_data_dir"
  fi

  if ! open_url_in_debug_browser "$debug_port" "$url"; then
    die "Debug browser failed to open $url via DevTools on port $debug_port"
  fi

  note "browser: started"
}
