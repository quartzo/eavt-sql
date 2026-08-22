#!/usr/bin/env bash
# stop.sh — Kill running EAVT servers and clean up sockets.
set -euo pipefail
cd "$(dirname "$0")/.."

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK_DIR="$XDG_RUNTIME_DIR/eavt"

# Kill by binary name (avoids matching the shell itself)
for name in eavt-sql-transactor eavt-sql-query; do
  pids=$(pgrep -x "$name" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    echo "killing $name (pids: $pids)"
    echo "$pids" | xargs -r kill 2>/dev/null || true
    sleep 0.3
    echo "$pids" | xargs -r kill -9 2>/dev/null || true
  fi
done

# Clean up sockets
rm -f "$SOCK_DIR/eavt-query.sock" "$SOCK_DIR/eavt-transactor.sock" 2>/dev/null || true
echo "stopped"
