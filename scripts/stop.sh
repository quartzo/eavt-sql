#!/usr/bin/env bash
# stop.sh — Kill running EAVT servers and clean up sockets.
set -euo pipefail
cd "$(dirname "$0")/.."

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK_DIR="$XDG_RUNTIME_DIR/eavt"

# Kill by binary path (comm is truncated to 15 chars on Linux, so -x on
# the full name never matches "eavt-sql-transactor")
for pat in "build/eavt-sql-transactor" "build/eavt-sql-query"; do
  pids=$(pgrep -f "$pat" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    echo "killing $pat (pids: $pids)"
    echo "$pids" | xargs -r kill 2>/dev/null || true
    sleep 0.3
    echo "$pids" | xargs -r kill -9 2>/dev/null || true
  fi
done

# Clean up sockets
rm -f "$SOCK_DIR/eavt-query.sock" "$SOCK_DIR/eavt-transactor.sock" 2>/dev/null || true
echo "stopped"
