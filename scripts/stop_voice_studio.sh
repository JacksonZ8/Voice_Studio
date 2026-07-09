#!/bin/zsh
set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PID_DIR="$PROJECT_ROOT/voice_studio/run"

stop_pid_file() {
  local file="$1"
  if [ -f "$file" ]; then
    local pid
    pid="$(cat "$file")"
    if /bin/kill -0 "$pid" >/dev/null 2>&1; then
      /bin/kill "$pid" >/dev/null 2>&1
    fi
    /bin/rm -f "$file"
  fi
}

stop_pid_file "$PID_DIR/backend.pid"
stop_pid_file "$PID_DIR/frontend.pid"

echo "Voice Studio local services stopped."
