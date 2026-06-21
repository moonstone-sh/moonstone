#!/usr/bin/env sh
set -eu

command_name="${1:-}"
state_dir="${METEORITE_DEV_STATE_DIR:-.meteorite/dev}"
pid_file="${METEORITE_DEV_PID_FILE:-$state_dir/server.pid}"
port="${METEORITE_DEV_PORT:-8080}"
server_path="${METEORITE_DEV_SERVER:-dist/server}"

usage() {
  cat >&2 <<USAGE
usage: scripts/guard.sh COMMAND

Commands:
  status       show tracked and port-listening server processes
  cleanup      terminate stale tracked/listening Meteorite dev servers
  cleanup-sessions
              terminate old moon run dev / dev.lua supervisors
  handoff      cleanup old supervisors, then assert the dev port is free
  stop         alias for cleanup
  assert-free  cleanup, then fail if the dev port is still occupied

Environment:
  METEORITE_DEV_STATE_DIR   default: .meteorite/dev
  METEORITE_DEV_PID_FILE    default: .meteorite/dev/server.pid
  METEORITE_DEV_PORT        default: 8080
  METEORITE_DEV_SERVER      default: dist/server
USAGE
}

mkdir -p "$state_dir"

is_running() {
  pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

command_for_pid() {
  pid="$1"
  ps -p "$pid" -o command= 2>/dev/null || true
}

is_meteorite_server() {
  pid="$1"
  cmd="$(command_for_pid "$pid")"
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    *"$server_path"*) return 0 ;;
    *"/dist/server"*) return 0 ;;
    *"dist/server"*) return 0 ;;
    *) return 1 ;;
  esac
}

tracked_pid() {
  if [ -f "$pid_file" ]; then
    sed -n 's/[^0-9].*$//; /^[0-9][0-9]*$/p; q' "$pid_file" 2>/dev/null || true
  fi
}

port_pids() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u || true
  fi
}

dev_session_pids() {
  exclude="${METEORITE_GUARD_EXCLUDE_PID:-}"
  ps -axo pid=,ppid=,command= 2>/dev/null | awk \
    -v self="$$" \
    -v parent="${PPID:-}" \
    -v exclude="$exclude" '
      /guard\.sh/ { next }
      /awk / { next }
      /src\/meteorite\/dev\.lua/ || /moon run dev/ {
        pid=$1
        ppid=$2
        if (pid == self || pid == parent || pid == exclude) next
        if (ppid == self || ppid == parent || ppid == exclude) next
        print pid
      }
    ' | sort -u || true
}

candidate_pids() {
  {
    tracked_pid
    port_pids
  } | awk 'NF && !seen[$1]++ { print $1 }'
}

terminate_pid() {
  pid="$1"
  if ! is_running "$pid"; then return 0; fi
  if ! is_meteorite_server "$pid"; then
    echo "guard: refusing to kill non-Meteorite process pid=$pid cmd=$(command_for_pid "$pid")" >&2
    return 1
  fi
  echo "guard: stopping Meteorite dev server pid=$pid" >&2
  kill "$pid" 2>/dev/null || true
  i=0
  while is_running "$pid" && [ "$i" -lt 20 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if is_running "$pid"; then
    echo "guard: force stopping Meteorite dev server pid=$pid" >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

status() {
  pid="$(tracked_pid)"
  if [ -n "$pid" ]; then
    if is_running "$pid"; then
      echo "tracked pid=$pid running cmd=$(command_for_pid "$pid")"
    else
      echo "tracked pid=$pid stale"
    fi
  else
    echo "tracked pid=none"
  fi
  listeners="$(port_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  echo "port $port listeners=${listeners:-none}"
  sessions="$(dev_session_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  echo "dev sessions=${sessions:-none}"
}

cleanup() {
  failed=0
  for pid in $(candidate_pids); do
    if is_running "$pid"; then
      terminate_pid "$pid" || failed=1
    fi
  done
  rm -f "$pid_file"
  return "$failed"
}

assert_free() {
  cleanup || true
  busy=0
  for pid in $(port_pids); do
    if is_running "$pid"; then
      echo "guard: port $port still occupied by pid=$pid cmd=$(command_for_pid "$pid")" >&2
      busy=1
    fi
  done
  return "$busy"
}

cleanup_sessions() {
  for pid in $(dev_session_pids); do
    if is_running "$pid"; then
      echo "guard: stopping stale Meteorite dev session pid=$pid cmd=$(command_for_pid "$pid")" >&2
      kill "$pid" 2>/dev/null || true
    fi
  done
}

handoff() {
  cleanup_sessions
  assert_free
}

case "$command_name" in
  status) status ;;
  cleanup-sessions) cleanup_sessions ;;
  handoff) handoff ;;
  cleanup|stop) cleanup ;;
  assert-free) assert_free ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
