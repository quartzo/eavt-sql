#!/usr/bin/env bash
# parity_repl.sh — run a mirrored session through the Nim and Go REPLs against
# a fresh, isolated stack each, and diff the output (tx ids normalized).
#
# Usage: scripts/parity_repl.sh
# Requires: build/eavt-sql-transactor, build/eavt-sql-query, build/eavt-sql-cli
#           (nimble dist) and build/eavt-sql-cli-go (go build).
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
SESSION="$ROOT/go/testdata/parity_session.txt"
WORK="$(mktemp -d /tmp/eavt-parity.XXXXXX)"
export XDG_RUNTIME_DIR="$WORK/run"
export XDG_DATA_HOME="$WORK/data"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME"

trans_pid=""
query_pid=""

cleanup() {
  [ -n "$query_pid" ] && kill "$query_pid" 2>/dev/null || true
  [ -n "$trans_pid" ] && kill "$trans_pid" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

for bin in build/eavt-sql-transactor build/eavt-sql-query build/eavt-sql-cli; do
  [ -x "$bin" ] || { echo "missing $bin — run: nimble dist" >&2; exit 1; }
done
if [ ! -x build/eavt-sql-cli-go ]; then
  (cd go && go build -o ../build/eavt-sql-cli-go ./cmd/eavt-repl)
fi

start_stack() {
  [ -n "$query_pid" ] && kill "$query_pid" 2>/dev/null || true
  [ -n "$trans_pid" ] && kill "$trans_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$XDG_DATA_HOME/eavt" "$XDG_RUNTIME_DIR/eavt"
  "$ROOT/build/eavt-sql-transactor" </dev/null >"$WORK/transactor.log" 2>&1 &
  trans_pid=$!
  for _ in $(seq 1 80); do
    [ -S "$XDG_RUNTIME_DIR/eavt/eavt-transactor.sock" ] && break
    sleep 0.25
  done
  sleep 0.3
  "$ROOT/build/eavt-sql-query" </dev/null >"$WORK/query.log" 2>&1 &
  query_pid=$!
  for _ in $(seq 1 80); do
    [ -S "$XDG_RUNTIME_DIR/eavt/eavt-query.sock" ] && break
    sleep 0.25
  done
  sleep 0.3
}

start_stack
"$ROOT/build/eavt-sql-cli" <"$SESSION" >"$WORK/nim.out" 2>&1 || true
start_stack
"$ROOT/build/eavt-sql-cli-go" <"$SESSION" >"$WORK/go.out" 2>&1 || true

norm() { sed -E 's/tx=[0-9]+/tx=<ID>/g'; }
norm <"$WORK/nim.out" >"$WORK/nim.norm"
norm <"$WORK/go.out" >"$WORK/go.norm"

if diff -u "$WORK/nim.norm" "$WORK/go.norm"; then
  echo "PARITY OK ($(wc -l <"$WORK/nim.norm") lines)"
else
  echo "PARITY DIFF: Nim and Go REPL output differ (tx ids normalized)" >&2
  exit 1
fi
