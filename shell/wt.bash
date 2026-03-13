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

wt() {
  local wt_bin target_path branch
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
      branch=${2-}
      "$wt_bin" "$@" || return $?
      if target_path=$("$wt_bin" cd "$branch"); then
        :
      else
        return $?
      fi
      builtin cd -- "$target_path"
      ;;
    *)
      "$wt_bin" "$@"
      ;;
  esac
}
