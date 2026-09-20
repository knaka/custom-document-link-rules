# vim: set filetype=sh tabstop=2 shiftwidth=2 expandtab :
# shellcheck shell=sh
set -- __LIB_CUI_SH "$@"; eval "shift; \${$1-false} || ! $1=true" && return # shpp:source_guard

if test "${BASH_VERSION+set}"; then eval 'cd "${BASH_SOURCE%[/\\]*}"' || cd .; elif test "${1-}" = _SCRDIR; then cd "$2" || exit; else cd "${0%[/\\]*}" || cd .; fi 2>/dev/null; set -- _SCRDIR . "$OLDPWD" "$@" # shpp:sources
. ./utils.sh
# shellcheck disable=SC1091
is_mise || . ./commands.sh
cd "$3" || exit; shift 3 # /shpp:sources

# Get a key from the user without echoing.
get_key() {
  # Bash and BusyBox Ash provide the `-s` (silent mode) option.
  if is_bbwin || is_bash_bin
  then
    local key
    # shellcheck disable=SC3045
    read -rsn1 key
    echo "$key"
    return
  fi
  if is_macos || is_linux
  then
    local saved_stty
    saved_stty="$(stty -g)" || return $?
    stty -icanon -echo
    dd bs=1 count=1 2>/dev/null
    stty "$saved_stty"
    return
  fi
  # Otherwise, the input is echoed
  read -r key
  echo "$key"
}

# [<message> [default]] Show a message and get input from the user.
prompt() {
  local message="${1:-Text}"
  local default="${2:-}"
  printf "%s: (%s) " "$message" "$default" >&2
  local response
  read -r response
  if test -z "$response"
  then
    response="$default"
  fi
  printf "%s" "$response"
}

# [<message> [default]] Print a message and get confirmation.
prompt_confirm() {
  local message="${1:-Text}"
  local default="${2:-n}"
  local selection
  case "$default" in
    (y|Y|yes|Yes|YES)
      default=y
      selection="Y/n"
      ;;
    (n|N|no|No|NO)
      default=n
      selection="y/N"
      ;;
    (*)
      echo "Invalid default value: $default" >&2
      return 1
  esac
  printf "%s [%s]: " "$message" "$selection" >&2
  local response
  response="$(get_key)"
  if test -z "$response"
  then
    response="$default"
  fi
  # Echoing.
  echo "$response" >&2
  case "$response" in
    (y|Y)
      return 0
      ;;
    (*)
      return 1
      ;;
  esac
}

# Alternative `gum choose` which takes value not label for `--selected=...`.
# - gum choose label:value options use value for --selected · Issue #958 · charmbracelet/gum https://github.com/charmbracelet/gum/issues/958
choose() {
  local arg
  local scanning_items=false
  local label_delimiter=
  local selected=
  for arg in "$@"
  do
    shift
    if ! "$scanning_items"
    then
      case "$arg" in
        (--label-delimiter=*) label_delimiter="${arg#*=}";;
        (--selected=*)
          selected="${arg#*=}"
          continue
          ;;
        (-*) ;;
        (*) scanning_items=true;;
      esac
    fi
    if "$scanning_items" && test -n "$label_delimiter" -a -n "$selected"
    then
      local value="${arg#*"$label_delimiter"}"
      local label="${arg%"$label_delimiter"*}"
      test "$value" = "$selected" && selected="$label"
    fi
    set -- "$@" "$arg"
  done
  test -n "$selected" && set -- --selected="$selected" "$@"
  gum choose "$@"
}
