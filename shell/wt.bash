_wt_bin_path() {
  local script_path script_dir
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    script_path=${BASH_SOURCE[0]}
  elif [ -n "${ZSH_VERSION:-}" ]; then
    script_path=${functions_source[wt]-${functions_source[_wt_bin_path]-}}
  else
    script_path=""
  fi
  [ -n "$script_path" ] || return 1

  script_dir=${script_path%/*}
  if [ "$script_dir" = "$script_path" ]; then
    script_dir=.
  fi

  script_dir=$(cd "$script_dir" && pwd -P)
  printf '%s\n' "$script_dir/../bin/wt"
}

_wt_output_field() {
  local output field prefix line trimmed stripped
  output=$1
  field=$2
  prefix="$field: "

  while IFS= read -r line; do
    stripped=$(printf '%s' "$line" | python3 -c 'import re,sys; print(re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", sys.stdin.read()), end="")')
    trimmed=$stripped
    while :; do
      case "$trimmed" in
        ' '*) trimmed=${trimmed# } ;;
        $'\t'*) trimmed=${trimmed#$'\t'} ;;
        *) break ;;
      esac
    done
    case "$trimmed" in
      "$prefix"*)
        printf '%s\n' "${trimmed#"$prefix"}"
        return 0
        ;;
    esac
  done <<EOF
$output
EOF

  return 1
}

_wt_run_and_capture_stdout() {
  local output_file exit_code
  output_file=$1
  shift

  : >"$output_file"
  if [ -n "${ZSH_VERSION:-}" ]; then
    setopt local_options pipe_fail 2>/dev/null || true
    "$@" | tee "$output_file"
    exit_code=${pipestatus[1]}
  else
    "$@" | tee "$output_file"
    exit_code=${PIPESTATUS[0]}
  fi

  return "$exit_code"
}

wt() {
  local wt_bin target_path branch rm_force rm_target current_root main_root current_branch common_dir new_output wt_status new_output_file
  wt_bin=$(_wt_bin_path)
  [ -x "$wt_bin" ] || {
    printf 'wt wrapper error: missing executable at %s\n' "$wt_bin" >&2
    return 1
  }

  if [ $# -eq 0 ]; then
    "$wt_bin"
    return $?
  fi

  case "$1" in
    cd)
      shift
      if target_path=$("$wt_bin" cd "$@"); then
        :
      else
        return $?
      fi
      builtin cd -- "$target_path"
      ;;
    new)
      new_output_file=$(mktemp)
      if [ -t 1 ]; then
        if _wt_run_and_capture_stdout "$new_output_file" env WT_FORCE_STDOUT_STYLE=1 "$wt_bin" "$@"; then
          wt_status=0
        else
          wt_status=$?
        fi
      elif _wt_run_and_capture_stdout "$new_output_file" "$wt_bin" "$@"; then
        wt_status=0
      else
        wt_status=$?
      fi
      new_output=$(<"$new_output_file")
      rm -f "$new_output_file"
      [ $wt_status -eq 0 ] || return $wt_status
      if target_path=$(_wt_output_field "$new_output" "worktree_path"); then
        :
      else
        printf 'wt wrapper error: missing worktree_path in wt new output\n' >&2
        return 1
      fi
      builtin cd -- "$target_path"
      ;;
    rm)
      shift
      rm_force=0
      rm_target=""

      while [ $# -gt 0 ]; do
        case "$1" in
          --force)
            rm_force=1
            ;;
          --help|-h)
            "$wt_bin" rm "$@"
            return $?
            ;;
          *)
            if [ -n "$rm_target" ]; then
              "$wt_bin" rm "$rm_target" "$@"
              return $?
            fi
            rm_target=$1
            ;;
        esac
        shift
      done

      if [ -n "$rm_target" ]; then
        if [ $rm_force -eq 1 ]; then
          "$wt_bin" rm --force "$rm_target"
        else
          "$wt_bin" rm "$rm_target"
        fi
        return $?
      fi

      current_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        "$wt_bin" rm
        return $?
      }
      common_dir=$(git -C "$current_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git -C "$current_root" rev-parse --git-common-dir)
      common_dir=$(cd "$common_dir" && pwd -P)
      main_root=$(dirname "$common_dir")

      if [ "$current_root" = "$main_root" ]; then
        "$wt_bin" rm
        return $?
      fi

      if [ $rm_force -ne 1 ] && [ -n "$(git -C "$current_root" status --porcelain --untracked-files=normal 2>/dev/null || true)" ]; then
        "$wt_bin" rm
        return $?
      fi

      current_branch=$(git -C "$current_root" branch --show-current 2>/dev/null || true)
      if [ -n "$current_branch" ]; then
        rm_target=$current_branch
      else
        rm_target=$(basename "$current_root")
      fi

      builtin cd -- "$main_root"
      if [ $rm_force -eq 1 ]; then
        "$wt_bin" rm --force "$rm_target"
      else
        "$wt_bin" rm "$rm_target"
      fi
      ;;
    merge)
      shift
      current_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        "$wt_bin" merge "$@"
        return $?
      }
      common_dir=$(git -C "$current_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git -C "$current_root" rev-parse --git-common-dir)
      common_dir=$(cd "$common_dir" && pwd -P)
      main_root=$(dirname "$common_dir")

      if [ "$current_root" = "$main_root" ]; then
        "$wt_bin" merge "$@"
        return $?
      fi

      if "$wt_bin" merge "$@"; then
        builtin cd -- "$main_root"
      else
        return $?
      fi
      ;;
    *)
      "$wt_bin" "$@"
      ;;
  esac
}
