#!/usr/bin/env bash
# dev.sh — run the EAVT SQL stack in the foreground:
#   data server (eavt-data.sock) + gateway (eavt.sock).
# Ctrl-C stops both.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR="build"
DATA_SERVER="$BIN_DIR/eavt-sql-server"
GATEWAY="$BIN_DIR/eavt-sql-gateway"

for bin in "$DATA_SERVER" "$GATEWAY"; do
  if [ ! -x "$bin" ]; then
    echo "missing $bin — run: nimble dist" >&2
    exit 1
  fi
done

data_pid=""
gw_pid=""

cleanup() {
  [ -n "$gw_pid" ] && kill "$gw_pid" 2>/dev/null || true
  [ -n "$data_pid" ] && kill "$data_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

"$DATA_SERVER" &
data_pid=$!
sleep 0.3

"$GATEWAY" &
gw_pid=$!

echo "stack up: gateway on \$(eavt.sock) → data server on \$(eavt-data.sock)"
wait
