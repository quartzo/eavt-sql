#!/usr/bin/env bash
# parity_stack.sh — run the mirrored session against a fresh Go stack and a
# fresh Nim stack (same Go REPL client on both) and diff the output.  This is
# storage+execution byte-for-byte parity, not just REPL formatting.
# (parity_repl.sh compares the two REPL clients over the Nim stack.)
#
# Usage: scripts/parity_stack.sh
# Requires: build/eavt-sql-{transactor,query} (nimble dist) and
#           build/eavt-sql-{transactor-go,query-go,cli-go} (go build).
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
SESSION="$ROOT/go/testdata/parity_session.txt"
WORK="$(mktemp -d /tmp/eavt-stack-parity.XXXXXX)"
export XDG_RUNTIME_DIR="$WORK/run"
export XDG_DATA_HOME="$WORK/data"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME"

trans_pid=""
query_pid=""

cleanup() {
  [ -n "$query_pid" ] && kill "$query_pid" 2>/dev/null || true
  [ -n "$trans_pid" ] && kill "$trans_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

for bin in build/eavt-sql-transactor build/eavt-sql-query \
           build/eavt-sql-transactor-go build/eavt-sql-query-go \
           build/eavt-sql-cli-go; do
  [ -x "$bin" ] || { echo "missing $bin — run: nimble dist" >&2; exit 1; }
done

# start_stack <kind> — kind is "nim" or "go"; always a fresh empty DB.
start_stack() {
  local kind="$1"
  [ -n "$query_pid" ] && kill "$query_pid" 2>/dev/null || true
  [ -n "$trans_pid" ] && kill "$trans_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$XDG_DATA_HOME/eavt" "$XDG_RUNTIME_DIR/eavt"
  local suffix=""
  if [ "$kind" = "go" ]; then suffix="-go"; fi
  "$ROOT/build/eavt-sql-transactor$suffix" </dev/null >"$WORK/$kind-transactor.log" 2>&1 &
  trans_pid=$!
  for _ in $(seq 1 80); do
    [ -S "$XDG_RUNTIME_DIR/eavt/eavt-transactor.sock" ] && break
    sleep 0.25
  done
  sleep 0.3
  "$ROOT/build/eavt-sql-query$suffix" </dev/null >"$WORK/$kind-query.log" 2>&1 &
  query_pid=$!
  for _ in $(seq 1 80); do
    [ -S "$XDG_RUNTIME_DIR/eavt/eavt-query.sock" ] && break
    sleep 0.25
  done
  sleep 0.3
}

norm() { sed -E 's/tx=[0-9]+/tx=<ID>/g; s#socket=[^ ]+#socket=<SOCK>#g'; }

start_stack nim
"$ROOT/build/eavt-sql-cli-go" "$XDG_RUNTIME_DIR/eavt/eavt-query.sock" \
  <"$SESSION" >"$WORK/nim.out" 2>&1 || true

start_stack go
"$ROOT/build/eavt-sql-cli-go" "$XDG_RUNTIME_DIR/eavt/eavt-query.sock" \
  <"$SESSION" >"$WORK/go.out" 2>&1 || true

norm <"$WORK/nim.out" >"$WORK/a.norm"
norm <"$WORK/go.out" >"$WORK/b.norm"

if diff -u "$WORK/a.norm" "$WORK/b.norm"; then
  echo "STACK PARITY OK ($(wc -l <"$WORK/a.norm") lines)"
else
  echo "STACK PARITY DIFF: Nim stack and Go stack output differ" >&2
  exit 1
fi
