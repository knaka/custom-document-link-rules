 # vim: set filetype=sh tabstop=2 shiftwidth=2 expandtab :
# shellcheck shell=sh
set -- __LIB_IP_SH "$@"; eval "shift; \${$1-false} || ! $1=true" && return # shpp:source_guard

if test "${BASH_VERSION+set}"; then eval 'cd "${BASH_SOURCE%[/\\]*}"' || cd .; elif test "${1-}" = _SCRDIR; then cd "$2" || exit; else cd "${0%[/\\]*}" || cd .; fi 2>/dev/null; set -- _SCRDIR . "$OLDPWD" "$@" # shpp:sources
. ./utils.sh
cd "$3" || exit; shift 3 # /shpp:sources

# List IP ports in use.
ip_ports_in_use() {
  if is_windows
  then
    # -a: Displays all connections and listening ports.
    # -n: Displays addresses and port numbers in numerical form.
    # -p protocol: Shows connections for the protocol specified by protocol.
    netstat.exe -a -n -p TCP | grep TCP | awk '{ print $2 }' | sed -n -e 's/^.*://p' | sort -n | uniq
  elif is_macos
  then
    # -a: Show the state of all sockets.
    # -n: Show numerical addresses instead of trying to determine symbolic host, port or user names.
    # -v: Verbose.
    # -s protocol: Display statistics for the specified protocol.
    netstat -anvp tcp | grep ^tcp4 | awk '{ print $4 }' | sed 's/.*\.//'
  elif is_linux
  then
    if ! command -v ss >/dev/null
    then
      if is_debian
      then
        echo "ss(8) not found. Please install iproute2 package." >&2
        exit 1
      fi
      echo "ss(8) not found." >&2
      exit 1
    fi
    # --tcp: Display TCP sockets.
    # --all: Display all sockets. (Not only listening sockets (-n), but also established connections.)
    # --numeric: Do not resolve service names.
    ss --tcp --all --numeric --no-header | awk '{ print $4 }' | sed -n -e 's/^.*://p'
  else
    echo "Not implemented (490a9b1)" >&2
    exit 1
  fi
}

# List free IP ports.
ip_free_ports() {
  init_temp_dir
  local port="$1"
  local end="$2"
  local priv_ports_path="$TEMP_DIR"/f5c41b5
  seq "$port" "$end" | sort >"$priv_ports_path"
  local used_ports_path="$TEMP_DIR"/6157e29
  ip_ports_in_use | sort >"$used_ports_path"
  comm -23 "$priv_ports_path" "$used_ports_path" | sort -n
}

ip_random_free_port() {
  local start=49152
  local end=65535
  local number=1
  OPTIND=1; while getopts _-: OPT
  do
    test "$OPT" = - && OPT="${OPTARG%%=*}" && OPTARG="${OPTARG#"$OPT"=}"
    case "$OPT" in
      (start) start="$OPTARG";;
      (end) end="$OPTARG";;
      (number) number="$OPTARG";;
      (*) echo "Unexpected option: $OPT" >&2; exit 1;;
    esac
  done
  shift $((OPTIND-1))
  ip_free_ports "$start" "$end" | shuf | head -n "$number" || test $? -eq "$RC_SIGPIPE"
}

# Wait for one or more servers to respond with HTTP. Checks each URL sequentially with a 60-second timeout per URL.
wait_for_http() {
  local url
  local max_attempts=60
  for url in "$@"
  do
    echo "Waiting for server at $url to be ready ..." >&2
    local attempts=0
    while :
    do
      # -s: silent mode (suppress progress/error output)
      # -o /dev/null: discard response body
      # -w "%{http_code}": print HTTP status code after transfers
      # 2>/dev/null: suppress stderr
      if curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q -e "20[0-9]" -e "40[0-9]"
      then
        echo "✓ Server is ready at $url" >&2
        break
      fi
      attempts=$((attempts + 1))
      if test $attempts -ge $max_attempts
      then
        echo "✗ Server at $url did not respond with 200 after $max_attempts seconds" >&2
        return 1
      fi
      sleep 1
    done
  done
}

# Open the URL in the browser.
browse() {
  if is_windows
  then
    PowerShell -NoProfile -Command "Start-Process '$1'"
    return $?
  fi
  if is_macos
  then
    open "$1"
    return $?
  fi
  xdg-open "$1"
}
