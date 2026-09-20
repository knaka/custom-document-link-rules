#!/usr/bin/env sh
# vim: set filetype=sh tabstop=2 shiftwidth=2 expandtab :
# shellcheck shell=sh
set -- __LIB_BUILD_SH "$@"; eval "shift; \${$1-false} || ! $1=true" && return # shpp:source_guard

if test "${BASH_VERSION+set}"; then eval 'cd "${BASH_SOURCE%[/\\]*}"' || cd .; elif test "${1-}" = _SCRDIR; then cd "$2" || exit; else cd "${0%[/\\]*}" || cd .; fi 2>/dev/null; set -- _SCRDIR . "$OLDPWD" "$@" # shpp:sources
. ./utils.sh
. ./worker.sh
cd "$3" || exit; shift 3 # /shpp:sources

# Check if the file(s) were updated after the destination(s). Meant for
# build-dependency checks: `updated sources... --after destinations...` tells
# you whether the sources have changed since the destinations were last built
# (also available as `newer sources... --than destinations...`, an alias
# below). Like a Makefile's implicit rule, a missing destination alone is
# enough to report "needs rebuild" (true), without even checking the other
# destinations. A destination directory that exists but is empty is treated
# the same way: there's no file left inside it to compare against, and an
# empty output directory more often means a failed/incomplete build than a
# legitimate zero-file one, so it's safer to report "needs rebuild" than to
# risk leaving a stale or missing build in place.
updated() {
  local found_than=false
  local psv_dests=
  local arg
  for arg in "$@"
  do
    shift
    if test "$arg" = "--after" -o "$arg" = "--than"
    then
      found_than=true
    elif $found_than
    then
      psv_dests="$psv_dests$arg|"
    else
      set -- "$@" "$arg"
    fi
  done
  if test -z "$psv_dests"
  then
    echo "Missing --after (or --than) option" >&2
    exit 1
  fi
  if test "$#" -eq 0
  then
    echo "No source files specified" >&2
    exit 1
  fi
  local dest
  local IFS="|"
  for dest in $psv_dests
  do
    unset IFS
    # If the destination does not exist, sources are considered newer than the destination.
    if ! test -e "$dest"
    then
      "${VERBOSE-false}" && echo "Destination does not exist: $dest" >&2
      return 0
    fi
    # If the destination is a directory, the newest file in the directory is used.
    if test -d "$dest"
    then
      local dest_dir="$dest"
      if is_bsd
      then
        dest="$(find "$dest" -type f -exec stat -l -t "%F %T" {} \+ | cut -d' ' -f6- | sort -n | tail -1 | cut -d' ' -f3)"
      else
        dest="$(find "$dest" -type f -exec stat -Lc '%Y %n' {} \+ | sort -n | tail -1 | cut -d' ' -f2)"
      fi
    fi
    if test -z "$dest"
    then
      echo "Destination directory is empty, needs rebuild: $dest_dir" >&2
      return 0
    fi
    if test -n "$(find "$@" -type f -a -newer "$dest" 2>/dev/null)"
    then
      return 0
    fi
  done
  unset IFS
  return 1
}

newer() {
  updated "$@"
}

# Returns true if no source file is newer than the destination file.
older() {
  ! newer "$@"
}

pid_4ec98eb=
fifo_path_4ec98eb=

on_exit_0e51f30() {
  if test -n "$pid_4ec98eb"
  then
    kill "$pid_4ec98eb" >/dev/null 2>&1 || :
    wait "$pid_4ec98eb" >/dev/null 2>&1 || :
    pid_4ec98eb=
  fi
  exec 8<&- || :
  test -n "$fifo_path_4ec98eb" && rm -f "$fifo_path_4ec98eb"
  fifo_path_4ec98eb=
}

# Block until a batch of changes to the given filter patterns is detected,
# then return success (0). Meant to be called repeatedly in a loop with the
# same patterns: `watchexec --only-emit-events` is started just once, on the
# first call, and kept running/streaming in the background across
# subsequent calls, rather than being relaunched every time. Returns
# failure (1) if the underlying watchexec process dies.
wait_for_change() {
  if test -z "$pid_4ec98eb"
  then
    local arg
    for arg in "$@"
    do
      shift
      # Watchexec accepts relative paths.
      arg="${arg#"$INITIAL_DIR"}"
      # Watchexec does not recognise preceding `./` in glob patterns.
      # — Glob pattern syntax and issues - Watchexec https://watchexec.github.io/docs/glob-patterns.html
      arg="${arg#.[/\\]}"
      set -- "$@" --filter="$arg"
    done

    trap_terminating_signals
    add_exit_handler on_exit_0e51f30
    init_temp_dir

    fifo_path_4ec98eb="$(mktemp "$TEMP_DIR"/XXXXXX)"
    rm -f "$fifo_path_4ec98eb"
    mkfifo "$fifo_path_4ec98eb"
    watchexec --no-discover-ignore --postpone \
      --only-emit-events --emit-events-to=stdio \
      "$@" >"$fifo_path_4ec98eb" 2>/dev/null &
    pid_4ec98eb=$!
    exec 8<"$fifo_path_4ec98eb"
  fi
  local line
  local line_prev="|"
  while IFS= read -r line <&8
  do
    test -z "$line" && return 0
    line="${line#*:}"
    if test "$line" != "$line_prev"
    then
      echo "$line"
    fi
    line_prev="$line"
  done
  return 1
}

# Incrementally build a target by running a handler only when its sources have
# changed, or keep doing so forever as they change. Usage:
#
#   incbuild [--force] [--handler=handler_cmd] target sources... [-- handler_cmd args...]
#
# The handler can be given either via --handler=handler_cmd or as trailing
# arguments after a `--` delimiter; at least one of the two is required. Without
# --watch, the handler runs once, and only if --force was given or `updated`
# reports the sources are newer than target (see `updated` above). With --watch,
# the handler instead runs every time `wait_for_change` (see above) reports a
# batch of changes to the sources, with the paths of the changed files appended
# to the handler's arguments; the first call runs immediately with no
# changed-file arguments, so the handler always fires at least once. Sources
# may be given as wildcard (glob) patterns instead of literal paths; this
# matters most with --watch, since the pattern is handed to `wait_for_change`
# as-is and keeps matching files created after the call, whereas expanding it
# up front would only capture what already existed.
incbuild() {
  local force=false
  local watch=false
  local handler=
  OPTIND=1; while getopts _-:B OPT
  do
    test "$OPT" = - && OPT="${OPTARG%%=*}" && OPTARG="${OPTARG#"$OPT"=}"
    case "$OPT" in
      (force|B|always-make) force=true;;
      (handler) handler="$OPTARG";;
      (watch) watch=true;;
      (?) return 1;;
      (*) echo "$0: illegal option -- $OPT" >&2; return 1;;
    esac
  done
  shift $((OPTIND-1))

  local target="$1"
  shift

  local usv_handler=
  local usv_sources=
  local found_delimiter=false
  local arg
  for arg in "$@"
  do
    shift
    if "$found_delimiter"
    then
      usv_handler="$usv_handler$arg$CH_US"
    elif test "$arg" = --
    then
      found_delimiter=true
    else
      usv_sources="$usv_sources$arg$CH_US"
    fi
  done

  if test -z "$usv_handler"
  then
    if test -n "$handler"
    then
      usv_handler="$handler$CH_US"
    else
      echo No handler specified. >&2
      return 1
    fi
  fi

  local IFS
  # shellcheck disable=SC2046 # Quote this to prevent word splitting.
  # shellcheck disable=SC2068 # Double quote array expansions to avoid re-splitting elements.
  # shellcheck disable=SC2086 # Double quote to prevent globbing and word splitting.
  if "$watch"
  then
    init_temp_dir
    local modified_file_list="$TEMP_DIR"/0ec5e8a
    rm -f "$modified_file_list"
    touch "$modified_file_list"
    while :
    do
      IFS="$CH_US"; set -- $usv_handler; unset IFS
      IFS="$CH_LF"; "$@" $(cat "$modified_file_list"); unset IFS
      sleep 1
      local disable_noglob=false
      case $- in (*f*) ;; (*) set -o noglob; disable_noglob=true;; esac
      IFS="$CH_US"; set -- $usv_sources; unset IFS
      "$disable_noglob" && set +o noglob
      wait_for_change "$@" >"$modified_file_list"
    done
    echo "Must be unreachable (a7a6f8e)." >&2
    return 1
  else
    local disable_noglob=false
    case $- in (*f*) ;; (*) set -o noglob; disable_noglob=true;; esac
    IFS="$CH_US"; set -- $usv_sources; unset IFS
    "$disable_noglob" && set +o noglob
    # IFS=; set -- $@; unset IFS # Normal glob
    IFS="$CH_LF"; set -- $(extglob "$@"); unset IFS
    if "$force" || updated "$@" --after "$target"
    then
      IFS="$CH_US"; set -- $usv_handler "$@"; unset IFS
      "$@"
    fi
  fi
}

# Run incbuild functions sequentially or in background.
incbuilds() {
  local watch=false
  local force=false
  OPTIND=1; while getopts _-: OPT
  do
    test "$OPT" = - && OPT="${OPTARG%%=*}" && OPTARG="${OPTARG#"$OPT"=}"
    case "$OPT" in
      (force) force=true;;
      (watch) watch=true;;
      (?) return 1;;
      (*) echo "$0: illegal option -- $OPT" >&2; return 1;;
    esac
  done
  shift $((OPTIND-1))

  local wids=
  if "$watch"
  then
    trap_terminating_signals
    init_worker_queue
  fi
  for incbuild in "$@"
  do
    if "$watch"
    then
      set -- run_worker "$incbuild" --watch
    else
      set -- "$incbuild"
    fi
    "$force" && set -- "$@" --force
    "$@"
    "$watch" && wids="$wids $WID"
  done
  # shellcheck disable=SC2086
  "$watch" && wait_worker $wids
  :
}
