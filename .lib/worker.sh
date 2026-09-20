#!/usr/bin/env sh
# vim: set filetype=sh tabstop=2 shiftwidth=2 expandtab :
# shellcheck shell=sh
set -- __LIB_WORKER_SH "$@"; eval "shift; \${$1-false} || ! $1=true" && return # shpp:source_guard

if test "${BASH_VERSION+set}"; then eval 'cd "${BASH_SOURCE%[/\\]*}"' || cd .; elif test "${1-}" = _SCRDIR; then cd "$2" || exit; else cd "${0%[/\\]*}" || cd .; fi 2>/dev/null; set -- _SCRDIR . "$OLDPWD" "$@" # shpp:sources
. ./utils.sh
cd "$3" || exit; shift 3 # /shpp:sources

# ==========================================================================
#region Workers

: "${worker_queue_dir_60742ac-}"

: "${WID-}"

# Start "$@" in the background and register it in the worker queue. $WID returns
# a worker ID that identifies it to every other function below.
#
# By default the worker is just a plain backgrounded process: `stop_worker`
# only signals that one process, so a well-behaved command that terminates
# its own children on SIGTERM needs nothing more. Pass `--group` to instead
# run the worker in its own process group (`stop_worker` then signals the
# whole group), for commands that don't propagate SIGTERM to children they
# spawn themselves.
#
# Caveat: on non-bash (see the `is_linux`/`is_macos` branches below),
# `--group` execs "$@" directly via `setsid`/Perl, so it must be a real
# executable on PATH, not a shell function defined in the caller — only the
# `is_bash_bin` branch backgrounds "$@" through the shell itself, so it can
# take a function. In practice this isn't a real limitation: a shell
# function is code you control, so just make it exit gracefully instead of
# reaching for `--group`.
run_worker() {
  local record_log=false
  local group=false
  local work_dir=.
  OPTIND=1; while getopts _-: OPT
  do
    test "$OPT" = - && OPT="${OPTARG%%=*}" && OPTARG="${OPTARG#"$OPT"=}"
    case "$OPT" in
      (group) group=true;;
      (record-log) record_log=true;;
      (cd|chdir) work_dir="$OPTARG";;
      (?) return 1;;
      (*) echo "$0: illegal option -- $OPT" >&2; return 1;;
    esac
  done
  shift $((OPTIND-1))

  local base log_file
  base="$(echo "$*" | sed -Ee 's/[^[:alnum:]]/_/g')"
  log_file="$(mktemp "$worker_queue_dir_60742ac"/"$base.log.XXXXX")"
  local wid
  if "$group"
  then
    local pid
    if is_bash_bin && ! is_brush
    then
      # Bash provides rich job control feature even on MSYS2.
      local disable_monitor=false
      case $- in (*m*) ;; (*) set -m; disable_monitor=true;; esac
      push_dir "$work_dir" || return 1
      # Run the background job and detach from the shell's job table so this
      # worker (though in its own process group via `set -m`) isn't reaped/awaited
      # by an unrelated bare `wait`/`jobs` the caller (who sourced this library)
      # might run later.
      if "$record_log"
      then
        "$@" </dev/null >"$log_file" 2>&1 &
      else
        "$@" </dev/null &
      fi
      pid=$!
      pop_dir
      "$disable_monitor" && set +m
      # shellcheck disable=SC3044
      disown %+
    elif is_linux || is_macos
    then
      local pid_file
      pid_file="$(mktemp "$TEMP_DIR"/XXXXXX)"
      if is_linux
      then
        # Run the backgrounding itself inside a subshell (rather than plain `setsid
        # ... &` here) so the worker's direct parent is this subshell, which exits
        # immediately after echoing its pid. That orphans the worker right away,
        # regardless of how the caller happens to invoke `run_worker` (e.g. even
        # without wrapping the call in `(...)`), so it can never be swept up by an
        # unrelated bare `wait`/`jobs` in the caller's shell. (POSIX sh has no
        # `disown` to do this explicitly.)
        (
          cd "$work_dir" || exit 1
          "$record_log" && exec >"$log_file" 2>&1
          setsid "$@" </dev/null &
          echo $! >"$pid_file"
        )
      elif is_macos
      then
        # No `setsid(1)` command on macOS, so call POSIX::setsid() from Perl
        # instead, right before exec'ing into "$@" (no extra fork: like `setsid(1)`
        # on Linux, the Perl process itself becomes the worker via exec, so its pid
        # stays the worker's pid). Wrapped in the same detaching subshell as the
        # Linux branch above, for the same reason.
        (
          cd "$work_dir" || exit 1
          "$record_log" && exec >"$log_file" 2>&1
          perl -e 'use POSIX "setsid"; setsid(); exec @ARGV' "$@" </dev/null &
          echo $! >"$pid_file"
        )
      fi
      read -r pid <"$pid_file"
      rm -f "$pid_file"
      # Both the `setsid(1)` and Perl branches above start a separate process
      # that calls setsid() itself, some time after it forks (Perl in
      # particular has to load the POSIX module first, which can be slow on a
      # cold filesystem cache, e.g. a fresh CI runner). Until that setsid()
      # call actually happens, the worker still belongs to *our* process
      # group, not group "$pid" yet. If a caller calls `stop_worker` in that
      # window, `kill -TERM -"$pid"` targets a process group that doesn't
      # exist yet, so it silently hits nothing and the worker survives.
      # Block here until the worker has actually become its own process-group
      # leader so callers never observe that race.
      local i=0
      while ! kill -0 -"$pid" >/dev/null 2>&1
      do
        i=$((i + 1))
        test "$i" -ge 50 && break
        sleep 0.1
      done
    else
      echo "Unexpected environment (a0002c4)." >&2
      return 1
    fi
    wid="g$pid"
  else
    local pid
    if is_brush
    then
      # On Brush shell, this in a subshell does not return PID.
      # > "$@" </dev/null &
      # > echo $! >"$pid_file"
      echo Not implemented. >&2
      exit 1
    elif is_bash_bin
    then
      push_dir "$work_dir" || exit 1
      if "$record_log"
      then
        "$@" </dev/null >"$log_file" 2>&1 &
      else
        "$@" </dev/null &
      fi
      pid="$!"
      # shellcheck disable=SC3044
      disown %+
      pop_dir
    else
      local pid_file
      pid_file="$(mktemp "$TEMP_DIR"/XXXXXX)"
      (
        cd "$work_dir" || exit 1
        "$record_log" && exec >"$log_file" 2>&1
        "$@" </dev/null &
        echo $! >"$pid_file"
      )
      read -r pid <"$pid_file"
      rm -f "$pid_file"
    fi
    wid="p$pid"
  fi
  echo "$wid" >>"$worker_queue_dir_60742ac"/wids
  WID="$wid"
  if "$record_log"
  then
    echo "$log_file" >"$worker_queue_dir_60742ac/log-file.$wid"
  fi
  echo "$@" >"$TEMP_DIR"/args."$wid"
}

# Stream the log output of the given workers (or all queued workers if none
# given) via `tail -f`.
tail_worker() {
  local exec=false
  OPTIND=1; while getopts _-: OPT
  do
    test "$OPT" = - && OPT="${OPTARG%%=*}" && OPTARG="${OPTARG#"$OPT"=}"
    case "$OPT" in
      (exec) exec=true;;
      (?) return 1;;
      (*) echo "$0: illegal option -- $OPT" >&2; return 1;;
    esac
  done
  shift $((OPTIND-1))

  if test $# -eq 0
  then
    # shellcheck disable=SC2046
    set -- $(cat "$worker_queue_dir_60742ac"/wids)
  fi
  local wid
  for wid in "$@"
  do
    if test -r "$worker_queue_dir_60742ac"/"log-file.$wid"
    then
      set -- "$@" "$(cat "$worker_queue_dir_60742ac"/"log-file.$wid")"
    fi
    shift
  done
  if test $# -eq 0
  then
    return
  fi
  if "$exec"
  then
    exec tail -f "$@"
  elif is_terminal
  then
    (
      set -m
      tail -f "$@" || :
    )
  else
    tail -f "$@"
  fi
}

run_rec_worker() {
  run_worker --record-log "$@"
}

run_log_worker() {
  run_worker --record-log "$@"
}

# Print the accumulated log output of the given workers (or all queued
# workers if none given).
log_worker() {
  if test $# -eq 0
  then
    # shellcheck disable=SC2046
    set -- $(cat "$worker_queue_dir_60742ac"/wids)
  fi
  local wid
  for wid in "$@"
  do
    if test -r "$worker_queue_dir_60742ac"/"log-file.$wid"
    then
      set -- "$@" "$(cat "$worker_queue_dir_60742ac"/"log-file.$wid")"
    fi
    shift
  done
  if test $# -gt 0
  then
    cat "$@"
  fi
  :
}

# Send SIGTERM to each given worker: the whole process group for a
# `--group` worker, just the process itself otherwise. With
# `--timeout-sec=N` (default: don't wait at all), also blocks for the
# workers to actually exit, printing progress/failure to stderr — N is a
# combined budget shared across all given workers, not N seconds each. If
# that budget runs out and a worker is still alive, it is force-killed
# (SIGKILL) by default; pass `--no-kill` to instead just report it as a
# failure and leave it running. `--no-kill` has no effect when
# `--timeout-sec` is left at its default of 0, since there's no waiting (and
# so no timeout to run out) in that case.
stop_worker() {
  local timeout_sec=0
  local no_kill=false
  OPTIND=1; while getopts _-: OPT
  do
    test "$OPT" = - && OPT="${OPTARG%%=*}" && OPTARG="${OPTARG#"$OPT"=}"
    case "$OPT" in
      (timeout-sec) timeout_sec="$OPTARG";;
      (no-kill) no_kill=true;;
      (?) return 1;;
      (*) echo "$0: illegal option -- $OPT" >&2; return 1;;
    esac
  done
  shift $((OPTIND-1))

  local wid pid
  for wid in "$@"
  do
    pid="${wid#?}"
    case "$wid" in
      (g*)
        # Signal the whole process group (`run_worker --group ...` starts each
        # job in its own group via `set -m` or setsid(1)), so any children the
        # worker itself backgrounded get terminated too, not just the worker's
        # top-level process.
        kill -TERM -"$pid" >/dev/null 2>&1 || :
        ;;
      (p*)
        kill -TERM "$pid" >/dev/null 2>&1 || :
        ;;
      (*)
        return 1
        ;;
    esac
  done
  if test "$timeout_sec" -eq 0
  then
    return 0
  fi
  sleep 0.1
  for wid in "$@"
  do
    while is_worker_alive "$wid"
    do
      if test "$timeout_sec" -eq 0
      then
        if "$no_kill"
        then
          echo "Failed to stop worker: \"$(cat "$TEMP_DIR"/args."$wid")\"" >&2
          return 1
        fi
        pid="${wid#?}"
        case "$wid" in
          (g*) kill -KILL -"$pid" >/dev/null 2>&1 || :;;
          (p*) kill -KILL "$pid" >/dev/null 2>&1 || :;;
        esac
        sleep 0.1
        if is_worker_alive "$wid"
        then
          echo "Failed to stop worker after SIGKILL: \"$(cat "$TEMP_DIR"/args."$wid")\"" >&2
          return 1
        fi
        break
      fi
      sleep 1
      timeout_sec=$((timeout_sec - 1))
    done
    echo "Stopped worker: \"$(cat "$TEMP_DIR"/args."$wid")\"" >&2
  done
  return 0
}

# Extract the underlying process ID from a wid.
pid_of_worker() {
  local wid="$1"
  local pid="${wid#?}"
  echo "$pid"
}

# Block until every given worker is alive, or until `--timeout-sec=N`
# (default: 10) elapses, in which case it prints a failure message to
# stderr and returns non-zero. N is a combined budget shared across all
# given workers, not N seconds each.
wait_worker_start() {
  local timeout_sec=10
  OPTIND=1; while getopts _-: OPT
  do
    test "$OPT" = - && OPT="${OPTARG%%=*}" && OPTARG="${OPTARG#"$OPT"=}"
    case "$OPT" in
      (timeout-sec) timeout_sec="$OPTARG";;
      (?) return 1;;
      (*) echo "$0: illegal option -- $OPT" >&2; return 1;;
    esac
  done
  shift $((OPTIND-1))

  local wid
  for wid in "$@"
  do
    while :
    do
      is_worker_alive "$wid" && break
      if test "$timeout_sec" -eq 0
      then
        echo "Timedout to wait start: \"$(cat "$TEMP_DIR"/args."$wid")\"" >&2
        return 1
      fi
      sleep 1
      timeout_sec=$((timeout_sec - 1))
    done
  done
}

# Return success only if every given worker is still running.
is_worker_alive() {
  local wid
  for wid in "$@"
  do
    local pid="${wid#?}"
    kill -0 "$pid" >/dev/null 2>&1 || return 1
  done
}

# Block until every given worker has exited, or until `--timeout-sec=N`
# (default: -1) elapses, in which case it prints a failure message to
# stderr and returns non-zero. N is a combined budget shared across all
# given workers, not N seconds each.
wait_worker() {
  local timeout_sec=-1
  OPTIND=1; while getopts _-: OPT
  do
    test "$OPT" = - && OPT="${OPTARG%%=*}" && OPTARG="${OPTARG#"$OPT"=}"
    case "$OPT" in
      (timeout-sec) timeout_sec="$OPTARG";;
      (?) return 1;;
      (*) echo "$0: illegal option -- $OPT" >&2; return 1;;
    esac
  done
  shift $((OPTIND-1))

  local wid
  for wid in "$@"
  do
    while :
    do
      is_worker_alive "$wid" || break
      if test "$timeout_sec" -eq 0
      then
        echo "Timedout to wait: \"$(cat "$TEMP_DIR"/args."$wid")\"" >&2
        return 1
      fi
      sleep 1
      test "$timeout_sec" -gt 0 && timeout_sec=$((timeout_sec - 1))
    done
  done
}

# Stop every worker still in the queue and remove the queue's temp
# directory. Registered by `init_worker_queue` to run automatically on
# EXIT, not meant to be called directly.
cleanup_worker_queue_f63891f() {
  trap "" TERM HUP INT
  # shellcheck disable=SC2046
  stop_worker --timeout-sec=10 $(cat "$worker_queue_dir_60742ac"/wids)
  rm -fr "$worker_queue_dir_60742ac"
}

# Set up the worker queue (temp directory + an EXIT-time cleanup that stops
# any workers still running). Call once before using any other function in
# this file; a no-op on repeat calls.
init_worker_queue() {
  first_call 6a52c6c || return 0
  if is_bash_bin || is_linux || is_macos
  then
    :
  else
    echo "Not supported (df631f1)." >&2
    return 1
  fi
  init_temp_dir
  worker_queue_dir_60742ac="$TEMP_DIR/worker-queue"
  mkdir -p "$worker_queue_dir_60742ac"
  touch "$worker_queue_dir_60742ac"/wids
  add_exit_handler cleanup_worker_queue_f63891f
  echo worker_queue_dir: "$worker_queue_dir_60742ac" >&2
}

#endregion

# ==========================================================================
#region Misc

pid_6848910=

cleanup_1e01b3a() {
  local rc=$?
  test "$rc" = "$RC_SIGTERM" && rc=0
  test -n "$pid_6848910" && {
    kill -TERM "$pid_6848910" || :
    wait "$pid_6848910" || :
    pid_6848910=
  } 2>/dev/null
  exit "$rc"
}

# Run "$@", then keep re-running it every `--interval-sec=N` (default: 10)
# seconds, forever, until a SIGTERM (or EXIT) arrives.
run_periodically() {
  local interval_sec=10
  OPTIND=1; while getopts _-: OPT
  do
    test "$OPT" = - && OPT="${OPTARG%%=*}" && OPTARG="${OPTARG#"$OPT"=}"
    case "$OPT" in
      (interval-sec) interval_sec="$OPTARG";;
      (?) return 1;;
      (*) echo "$0: illegal option -- $OPT" >&2; return 1;;
    esac
  done
  shift $((OPTIND-1))

  add_signal_handler cleanup_1e01b3a EXIT
  while :
  do
    "$@"
    sleep "$interval_sec" &
    pid_6848910=$!
    local rc=0
    wait "$pid_6848910" || rc=$?
    if test "$rc" -ne 0
    then
      test "$rc" -eq "$RC_SIGTERM" && break
      return "$rc"
    fi
  done
}

#endregion
