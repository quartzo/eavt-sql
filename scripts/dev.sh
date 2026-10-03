#!/usr/bin/env bash
# dev.sh — run the EAVT SQL stack in the foreground:
#   transactor (eavt-transactor.sock) + query server (eavt-query.sock).
# Ctrl-C stops both.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR="build"
TRANSACTOR="$BIN_DIR/eavt-sql-transactor"
QUERY="$BIN_DIR/eavt-sql-query"

for bin in "$TRANSACTOR" "$QUERY"; do
  if [ ! -x "$bin" ]; then
    echo "missing $bin — run: nimble dist" >&2
    exit 1
  fi
done

trans_pid=""
query_pid=""

cleanup() {
  [ -n "$query_pid" ] && kill "$query_pid" 2>/dev/null || true
  [ -n "$trans_pid" ] && kill "$trans_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

"$TRANSACTOR" &
trans_pid=$!
sleep 0.3

"$QUERY" &
query_pid=$!

echo "stack up: query server on eavt-query.sock → transactor on eavt-transactor.sock"
wait
