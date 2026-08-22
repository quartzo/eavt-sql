#!/usr/bin/env bash
# start.sh — Start EAVT servers with a fresh database.
# Usage: start.sh [--keep-db]
#   --keep-db  Don't delete the existing database before starting.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR="build"
TRANSACTOR="$BIN_DIR/eavt-sql-transactor"
QUERY="$BIN_DIR/eavt-sql-query"
DB_DIR="${HOME}/.local/state/eavt/db"
LOG_DIR="/tmp"

KEEP_DB=false
for arg in "$@"; do
  case "$arg" in
    --keep-db) KEEP_DB=true ;;
  esac
done

for bin in "$TRANSACTOR" "$QUERY"; do
  if [ ! -x "$bin" ]; then
    echo "missing $bin — run: nimble dist" >&2
    exit 1
  fi
done

# Stop any running instances first
"$(dirname "$0")/stop.sh"

# Clean database unless --keep-db
if [ "$KEEP_DB" = false ]; then
  rm -rf "$DB_DIR"
fi

# Start transactor
nohup "$TRANSACTOR" </dev/null >"$LOG_DIR/transactor.log" 2>&1 &
trans_pid=$!
echo "transactor started (pid $trans_pid)"

# Wait for transactor socket
for i in $(seq 1 20); do
  if [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/eavt/eavt-transactor.sock" ]; then
    break
  fi
  sleep 0.2
done

# Start query server
nohup "$QUERY" </dev/null >"$LOG_DIR/query.log" 2>&1 &
query_pid=$!
echo "query server started (pid $query_pid)"

# Wait for query socket
for i in $(seq 1 20); do
  if [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/eavt/eavt-query.sock" ]; then
    break
  fi
  sleep 0.2
done

echo "stack up: query server on eavt-query.sock → transactor on eavt-transactor.sock"
echo "logs: $LOG_DIR/transactor.log $LOG_DIR/query.log"
echo "stop: scripts/stop.sh"
