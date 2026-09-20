#!/usr/bin/env sh
# vim: set filetype=sh tabstop=2 shiftwidth=2 expandtab :
# shellcheck shell=sh
# shellcheck disable=SC2034 # ShellCheck: SC2034 – foo appears unused. Verify it or export it. https://www.shellcheck.net/wiki/SC2034
set -- __LIB_UTILS_SH "$@"; eval "shift; \${$1-false} || ! $1=true" && return # shpp:source_guard

# ==========================================================================
#region Global variables.

# The initial working directory when the command was started.
: "${INITIAL_DIR:=${MISE_ORIGINAL_CWD-}}" # https://mise.jdx.dev/tasks/toml-tasks.html
: "${INITIAL_DIR:=${INIT_CWD-}}" # https://docs.npmjs.com/cli/v8/using-npm/scripts
test -z "$INITIAL_DIR" && unset INITIAL_DIR

# Current project directory.
: "${PROJECT_DIR:=${MISE_PROJECT_ROOT-}}"
test -z "$PROJECT_DIR" && unset PROJECT_DIR

# The project directory where the task is defined.
: "${TASK_PROJECT_DIR:=${MISE_CONFIG_ROOT-}}"
: "${TASK_PROJECT_DIR:=${_APPDIR-}}"
test -z "$TASK_PROJECT_DIR" && unset TASK_PROJECT_DIR

# Verbosity.
: "${VERBOSE-}"

#endregion

# ==========================================================================
#region Platform detection. Detect platform without using subprocesses whenever possible, since subprocess creation is expensive and these functions are called frequently.

# Windows
is_windows() {
  test -d \\
}

# MSYS2 on Windows
is_msys2() {
  test -d \\ -a -d /proc
}

# BusyBox for Windows Ash
is_bbwin() {
  test -d \\ -a ! -d /proc -a "${BB_GLOBBING+set}"
}

is_macos() {
  test -f /System/Library/CoreServices/SystemVersion.plist
}

is_bsd() {
  is_macos || test -r /etc/rc.subr
}

is_mise() {
  test "${MISE_CONFIG_ROOT+set}"
}

is_linux() {
  # MSYS2 has /proc dir.
  test -d /proc -a -d /sys/kernel
  # Strict check
  # test -r /proc/sys/kernel/ostype \
  #   && read -r RESULT </proc/sys/kernel/ostype \
  #   && test "$RESULT" = Linux
}

is_debian() {
  test -f /etc/debian_version
}

is_alpine() {
  test -f /etc/alpine-release
}

is_bash_bin() {
  if test $# -eq 0
  then
    test "${BASH_VERSION+set}"
  else
    # shellcheck disable=SC3028
    # shellcheck disable=SC3054
    is_bash_bin && test "${BASH_VERSINFO[0]}" -ge "$1"
  fi
}

is_bash_posix() {
  # shellcheck disable=SC3010
  # shellcheck disable=SC3028
  is_bash_bin "$@" && [[ ":$SHELLOPTS:" = *:posix:* ]]
}

is_bash_native() {
  # shellcheck disable=SC3010
  # shellcheck disable=SC3028
  is_bash_bin "$@" && [[ ":$SHELLOPTS:" != *:posix:* ]]
}

is_brush() {
  test "${BRUSH_VERSION+set}"
}

# Executable file extension.
EXE_EXT=
if is_windows
then
  EXE_EXT=.exe
fi
readonly EXE_EXT

#endregion

# ==========================================================================
#region Basic utilities.

readonly CH_LF="
"
readonly CH_TAB="	"
readonly CH_ESC=""
readonly CH_SPC=" "

# Unit separator (US), Information Separator 1
readonly CH_US=""
readonly CH_IS1="$CH_US"
# Record separator (RS), Information Separator 2
readonly CH_RS=""
readonly CH_IS2="$CH_RS"
# Group separator (GS), Information Separator 3
readonly CH_GS=""
readonly CH_IS3="$CH_GS"
# File separator (FS), Information Separator 4
readonly CH_FS=""
readonly CH_IS4="$CH_FS"

readonly SIGHUP=1
readonly SIGINT=2
readonly SIGPIPE=13
readonly SIGALRM=14
readonly SIGTERM=15

: "${SIGUSR1-}"
: "${SIGUSR2-}"
if is_msys2 || is_macos
then
  SIGUSR1=30
  SIGUSR2=31
elif is_linux
then
  SIGUSR1=10
  SIGUSR2=12
fi
if test -n "${SIGUSR1-}"
then
  readonly SIGUSR1
  readonly SIGUSR2
fi

readonly RC_SIGHUP=$((128 + SIGHUP))
readonly RC_SIGINT=$((128 + SIGINT))
readonly RC_SIGPIPE=$((128 + SIGPIPE))
readonly RC_SIGALRM=$((128 + SIGALRM))
readonly RC_SIGTERM=$((128 + SIGTERM))

: "${RC_SIGUSR1-}"
: "${RC_SIGUSR2-}"
if test -n "${SIGUSR1-}"
then
  readonly RC_SIGUSR1=$((128 + SIGUSR1))
  readonly RC_SIGUSR2=$((128 + SIGUSR2))
fi

foo_404b37f() {
  :
}

# The EXIT handler runs when the script runs to the end, or when the `exit`
# builtin is called. In Bash, it also runs on receiving a terminating signal.
# shellcheck disable=SC2064
trap_terminating_signals() {
  trap "exit $RC_SIGHUP" HUP
  trap "exit $RC_SIGINT" INT
  trap "exit $RC_SIGPIPE" PIPE
  trap "exit $RC_SIGALRM" ALRM
  trap "exit $RC_SIGTERM" TERM
  local signal
  for signal in "$@"
  do
    trap exit "$signal"
  done
}

usv_called_25b9fbb=

# Guard against multiple calls. $1 is a unique ID. Calls from a different directory are regarded as different calls.
first_call() {
  case "$CH_US$usv_called_25b9fbb" in
    (*"$CH_US$PWD|$1$CH_US"*)
      return 1
      ;;
  esac
  usv_called_25b9fbb="$PWD|$1$CH_US$usv_called_25b9fbb"
}

# Check if stdio is tty.
is_terminal() {
  test -t 0 -a -t 1
}

usv_called_6b2a1df=

# Run only once. Calls from a different directory are regarded as different calls.
run_once() {
  case "$CH_US$usv_called_6b2a1df" in
    (*"$CH_US$PWD|$*$CH_US"*)
      return 0
      ;;
  esac
  usv_called_6b2a1df="$usv_called_6b2a1df$PWD|$*$CH_US"
  "$@"
}

#endregion

# ==========================================================================
#region Temporary directory and cleaning up

: "${TEMP_DIR-}"

# Traps are reset in subshells, so "${signal}_cmds" must be reset too.
# — Command Execution Environment (Bash Reference Manual) https://doc.guix.gnu.org/bash/latest/en/html_node/Command-Execution-Environment.html
# shellcheck disable=SC3028
reset_cmds_if_new_subshell_f2fb3bc() {
  local signal="$1"
  local cmds_var_name="${signal}_cmds_054cf7c"
  local bashpid_var_name="${signal}_prev_bashpid_73b382c"
  if eval test \$"$cmds_var_name" != :
  then
    # Note that `trap -p ...` of Bash >= 4 output inside a Bash subshell
    # reflects the parent shell's state, so it cannot be relied on for this
    # check.
    if eval "test -n \"\$$bashpid_var_name\"" # Bash >= 4
    then
      if eval test "\$$bashpid_var_name" != "$BASHPID"
      then
        eval "$cmds_var_name=:"
      fi
    else # The others
      # Piping directly into grep would check the subshell's own trap (since a
      # pipeline stage runs in a subshell), so write the parent shell's trap
      # state to a temp file first and grep that instead.
      local temp_file
      if test "${TEMP_DIR+set}"
      then
        temp_file="$TEMP_DIR"/16979dd
      else
        temp_file="$(mktemp)"
      fi
      trap >"$temp_file"
      if ! grep -E -e "[[:space:]]$signal\$" "$temp_file" >/dev/null 2>&1
      then
        eval "$cmds_var_name=:"
      fi
      rm -f "$temp_file"
    fi
  fi
  test "${BASHPID+set}" && eval "$bashpid_var_name=$BASHPID" || :
}

signal_valid_6fbb8c5() {
  local haystack=",EXIT,TERM,"
  local signal
  for signal in "$@"
  do
    case "$haystack" in
      (*,$signal,*) ;;
      (*) return 1;;
    esac
  done
}

add_signal_handler() {
  local signal_handler="$1"
  shift
  signal_valid_6fbb8c5 "$@" || return
  local signal
  for signal in "$@"
  do
    reset_cmds_if_new_subshell_f2fb3bc "$signal"
    local cmds_var_name="${signal}_cmds_054cf7c"
    local haystack=
    eval "haystack=\";\$$cmds_var_name;\""
    case "$haystack" in
      (*";${signal_handler};"*) return 0;;
    esac
    local cmds=
    eval "cmds=\"$signal_handler;\$$cmds_var_name\""
    eval "$cmds_var_name=\"$cmds\""
    # shellcheck disable=SC2064
    trap "$cmds" "$signal"
  done
}

remove_signal_handler_6b58050() {
  local signal_handler="$1"
  shift
  signal_valid_6fbb8c5 "$@" || return
  local signal
  for signal in "$@"
  do
    local cmds_var_name="${signal}_cmds_054cf7c"
    reset_cmds_if_new_subshell_f2fb3bc "$signal"
    local haystack=
    eval haystack="\";\$$cmds_var_name;\""
    local cmds
    cmds="$(echo "$haystack" | sed -e "s/;$signal_handler;//" -e 's/^;//' -e 's/;$//')"
    eval "$cmds_var_name=\"$cmds\""
    # shellcheck disable=SC2064
    trap "$cmds" "$signal"
  done
}

EXIT_cmds_054cf7c=:
EXIT_prev_bashpid_73b382c=

add_exit_handler() {
  add_signal_handler "$1" EXIT
}

remove_exit_handler() {
  remove_signal_handler_6b58050 "$1" EXIT
}

cleanup_temp_dir_a395082() {
  rm -fr "$TEMP_DIR"
  unset TEMP_DIR
}

# Create a temporary directory and assign $TEMP_DIR env var
init_temp_dir() {
  test "${TEMP_DIR+set}" && return 0
  TEMP_DIR="$(mktemp -d)"
  add_exit_handler cleanup_temp_dir_a395082
}

cleanup_child_processes() {
  "${VERBOSE-false}" && echo Cleaning up child processes >&2
  if is_bbwin
  then
    kill -TERM -$$ || return $?
    return
  fi
  kill -TERM 0
}

# Register the child-processes cleanup trap handler. Note that, as a result, a
# TERM signal is sent to the entire process group.
register_child_cleanup() {
  first_call 5f719a3 || return 0
  add_exit_handler cleanup_child_processes
  # Deliberately `trap : TERM` (a no-op command), not `trap "" TERM`: the
  # latter sets SIG_IGN, which — unlike a trap with an actual command — is
  # inherited by subshells and exec'd children, which we don't want here.
  trap : TERM
}

# Call the finalization function before `exec` which does not call trap function.
run_exit_handlers() {
  reset_cmds_if_new_subshell_f2fb3bc EXIT
  $EXIT_cmds_054cf7c
  EXIT_cmds_054cf7c=:
}

clean_exec() {
  run_exit_handlers
  exec "$@"
}

# SIGTERM handler stack.

TERM_cmds_054cf7c=:
TERM_prev_bashpid_73b382c=

add_term_handler() {
  add_signal_handler "$1" TERM
}

remove_term_handler() {
  remove_signal_handler_6b58050 "$1" TERM
}

#endregion

# ==========================================================================
#region Directory stack.

psv_dirs_4c15d80=""

# `pushd` alternative.
push_dir() {
  local pwd="$PWD"
  if ! cd "$1" 2>/dev/null
  then
    echo "Directory does not exist: $1" >&2
    return 1
  fi
  psv_dirs_4c15d80="$pwd|$psv_dirs_4c15d80"
}

# `popd` alternative.
pop_dir() {
  if test -z "$psv_dirs_4c15d80"
  then
    echo "Directory stack is empty" >&2
    return 1
  fi
  local dir="${psv_dirs_4c15d80%%|*}"
  psv_dirs_4c15d80="${psv_dirs_4c15d80#*|}"
  cd "$dir" || return 1
}

#endregion

# ==========================================================================
#region Misc utilities.

# Print call stack if available.
print_call_stack() {
  if test $# -gt 0
  then
    # shellcheck disable=SC2059
    echo "$@" >&2
  fi
  # shellcheck disable=SC3018
  # shellcheck disable=SC3044
  if is_bash_bin
  then
    local i=0 frame
    while frame="$(caller $i)"
    do
      # shellcheck disable=SC2086
      set -- $frame
      local line="$1"
      local sub="$2"
      local file="$3"
      printf "  at %s (%s:%s)\n" "$sub" "$(realpath -q "$file" || echo "$file")" "$line" >&2
      i=$((i + 1))
    done
  else
    echo "  at $0" >&2
  fi
  :
}

# Check if external command exists in $PATH.
has_external_command() {
  # test -x "$(command -v "$1" 2>/dev/null)"
  # command which "$1" >/dev/null # `command` does not ignore builtins
  # env which "$1" >/dev/null
  which "$1" >/dev/null
}

: "${RESULT-}"

set_() {
  RESULT="$1"
}

# Assign stdin input stream to variable, preserving whether the input ends with
# a trailing newline.
assign_stdin() {
  local var_name="$1"
  if is_bash_bin
  then
    eval "IFS='' read -r -d '' \"$var_name\"" || :
    return
  fi
  eval "$var_name="
  local REPLY
  while :
  do
    if ! IFS='' read -r REPLY
    then
      test -n "$REPLY" && eval "$var_name=\"\$$var_name\$REPLY\""
      break
    fi
    eval "$var_name=\"\$$var_name\$REPLY\$CH_LF\""
  done
}

printf_() {
  if is_bash_bin
  then
    # shellcheck disable=SC2059
    # shellcheck disable=SC3045
    printf -v RESULT "$@"
  else
    local file_path
    file_path="$(mktemp)"
    # shellcheck disable=SC2059
    printf "$@" >"$file_path"
    RESULT=
    assign_stdin RESULT <"$file_path"
    rm -f "$file_path"
  fi
}

# Canonicalize path
canon_path() {
  local target="$1"
  is_msys2 && target="$(cygpath -u "$target")"
  realpath "$target"
}

# Check if root directory
is_root_dir() {
  local dir="$1"
  dir="$(canon_path "$dir")"
  local parent_dir
  parent_dir="$(dirname "$dir")"
  test "$dir" = "$parent_dir"
}

if is_macos
then
  shuf() {
    sort -R "$@"
  }

  tac() {
    tail -r
  }
fi

# Left/Right-Word-Boundary regex is incompatible with BSD sed // re_format(7) https://man.freebsd.org/cgi/man.cgi?query=re_format&sektion=7
LWB='\<'
RWB='\>'
if is_bsd
then
  LWB='[[:<:]]'
  RWB='[[:>:]]'
fi
readonly LWB RWB

# Get the space-separated nth (1-based) field.
field() {
  # Print 1-indexed n-th field of input lines.
  awk "{ print \$${1}} "
}

# Expand one or more extended glob patterns (globstar `**`, brace `{a,b}`,
# ksh-style `!(...)`/`@(...)` etc.) into the matching file names, one per line.
# /bin/sh itself has no such support, so this shells out to an interpreter that
# does: zsh (`setopt extendedglob`) on macOS, or a modern bash (`shopt -s
# extglob globstar`) on Linux/MSYS2. Returns failure if neither interpreter is
# available.
extglob() {
  if is_macos # Zsh
  then
    zsh -c 'setopt extendedglob nullglob; printf "%s\n" $~*' "" "$@"
  elif is_msys2 || is_linux # Bash >= 4
  then
    bash -O extglob -O globstar -c 'shopt -s nullglob; IFS=; printf "%s\n" $*' "" "$@"
  else
    echo "No shell interpreter available that can expand extended glob patterns." >&2
    return 1
  fi
}

# Return success if the given FD number is currently open (any mode).
is_fd_open() {
  { : >&"$1"; } 2>/dev/null
}

# Number of ancestor calls on the Bash function call stack that have
# explicitly opted in to being skipped over by `tail_exec` (see below), by
# invoking their own callee with `TAIL_DEPTH=$((TAIL_DEPTH+1))` prefixed to
# the call. Compared against `${#FUNCNAME[@]}` to detect whether every
# frame between the top-level entry point and `tail_exec` has opted in.
: "${TAIL_DEPTH:=0}"

# Exec only if every caller on the function call stack has declared that this is a "tail" call. Otherwise simply call it.
tail_exec() {
  # `+2` accounts for excluding the top-level frame (`main`) and this function itself.
  if "${FORCE_EXEC-false}" || { test "${BASH_VERSION+set}" && eval 'test ${#FUNCNAME[@]} -eq $((TAIL_DEPTH+2))'; }
  then
    set -- exec "$@"
    run_exit_handlers
  fi
  "$@"
}

#endregion
