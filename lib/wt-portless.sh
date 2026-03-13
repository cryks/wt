inspect_portless_dev_script() {
  local target_root
  target_root=$1
  require_python3

  python3 - "$target_root" <<'PY'
import json
import os
import re
import shlex
import sys

target_root = sys.argv[1]
package_json = os.path.join(target_root, "package.json")
with open(package_json, "r", encoding="utf-8") as handle:
    data = json.load(handle)

scripts = data.get("scripts") or {}
dev = scripts.get("dev")
if not isinstance(dev, str) or not dev.strip():
    raise SystemExit("package.json does not contain a non-empty scripts.dev command")

tokens = shlex.split(dev, posix=True)
assignment_pattern = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
index = 0
while index < len(tokens) and assignment_pattern.match(tokens[index]):
    index += 1

if index >= len(tokens) or os.path.basename(tokens[index]) != "portless":
    raise SystemExit("scripts.dev is not a portless command")

index += 1
reserved = {"run", "get", "alias", "hosts", "list", "trust", "proxy"}

def take_value(token_index):
    if token_index + 1 >= len(tokens):
        raise SystemExit("Missing value for portless option")
    value = tokens[token_index + 1]
    if not value or value.startswith("-"):
        raise SystemExit("Missing value for portless option")
    return value, token_index + 2

if index < len(tokens) and tokens[index] == "run":
    index += 1
    explicit_name = ""
    while index < len(tokens):
      token = tokens[index]
      if token == "--":
          break
      if token == "--name":
          explicit_name, index = take_value(index)
          continue
      if token in {"--force", "--https", "--no-tls", "--foreground"}:
          index += 1
          continue
      if token in {"--app-port", "--port", "-p", "--cert", "--key", "--tld"}:
          _, index = take_value(index)
          continue
      if token.startswith("-"):
          raise SystemExit(f"Unsupported portless run option in scripts.dev: {token}")
      break

    if explicit_name:
        print(f"explicit\t{explicit_name}")
    else:
        print("infer\t")
    raise SystemExit(0)

explicit_name = ""
while index < len(tokens) and tokens[index].startswith("-"):
    token = tokens[index]
    if token == "--name":
        explicit_name, index = take_value(index)
        continue
    if token in {"--force", "--https", "--no-tls", "--foreground"}:
        index += 1
        continue
    if token in {"--app-port", "--port", "-p", "--cert", "--key", "--tld"}:
        _, index = take_value(index)
        continue
    if token == "--":
        index += 1
        break
    raise SystemExit(f"Unsupported portless option in scripts.dev: {token}")

if explicit_name:
    print(f"explicit\t{explicit_name}")
    raise SystemExit(0)

if index >= len(tokens):
    raise SystemExit("Unable to determine the portless app name from scripts.dev")

name = tokens[index]
if name in reserved:
    raise SystemExit(f"Reserved portless subcommand used without --name: {name}")

print(f"explicit\t{name}")
PY
}

infer_portless_base_name() {
  local target_root
  target_root=$1
  require_python3

  python3 - "$target_root" <<'PY'
import json
import os
import subprocess
import sys

target_root = os.path.abspath(sys.argv[1])

cursor = target_root
while True:
    package_json = os.path.join(cursor, "package.json")
    if os.path.isfile(package_json):
        try:
            with open(package_json, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"Invalid JSON in {package_json}: {exc}")
        name = data.get("name")
        if isinstance(name, str) and name.strip():
            print(name.strip())
            raise SystemExit(0)
    parent = os.path.dirname(cursor)
    if parent == cursor:
        break
    cursor = parent

try:
    common_dir = subprocess.check_output(
        ["git", "-C", target_root, "rev-parse", "--path-format=absolute", "--git-common-dir"],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()
except subprocess.CalledProcessError:
    common_dir = ""

if common_dir:
    repo_root = os.path.dirname(os.path.realpath(common_dir))
    repo_name = os.path.basename(repo_root)
    if repo_name:
        print(repo_name)
        raise SystemExit(0)

basename = os.path.basename(target_root)
if basename:
    print(basename)
    raise SystemExit(0)

raise SystemExit("Unable to infer a portless app name for this worktree")
PY
}

derive_portless_base_name() {
  local target_root mode explicit_name
  target_root=$1
  IFS=$'\t' read -r mode explicit_name <<EOF
$(inspect_portless_dev_script "$target_root")
EOF

  case "$mode" in
    explicit)
      [ -n "$explicit_name" ] || die "Unable to determine the explicit portless app name for: $target_root"
      printf '%s\n' "$explicit_name"
      ;;
    infer)
      infer_portless_base_name "$target_root"
      ;;
    *)
      die "Unable to derive a portless app name for: $target_root"
      ;;
  esac
}

derive_portless_url() {
  local target_root base_name url
  target_root=$1
  base_name=$(derive_portless_base_name "$target_root")
  require_command portless
  url=$(cd "$target_root" && portless get "$base_name") || die "Failed to derive a portless URL from package.json scripts.dev in: $target_root"
  [ -n "$url" ] || die "portless get returned an empty URL for: $target_root"
  printf '%s\n' "$url"
}
