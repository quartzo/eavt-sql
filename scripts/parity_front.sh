#!/usr/bin/env bash
# parity_front.sh — A/B the Go query front against the Nim query front over
# the same Nim back, using the Go REPL for both.  Fresh isolated stack (and
# a fresh DB) for each side; output diffed with tx ids and the socket path
# normalized.
#
# Usage: scripts/parity_front.sh
# Requires: build/eavt-sql-{transactor,query,cli} (nimble dist) and
#           build/eavt-sql-{cli-go,query-front-go} (nimble dist / go build).
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
SESSION="$ROOT/go/testdata/parity_session.txt"
WORK="$(mktemp -d /tmp/eavt-front-parity.XXXXXX)"
export XDG_RUNTIME_DIR="$WORK/run"
export XDG_DATA_HOME="$WORK/data"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME"

trans_pid=""
query_pid=""
front_pid=""

cleanup() {
  [ -n "$front_pid" ] && kill "$front_pid" 2>/dev/null || true
  [ -n "$query_pid" ] && kill "$query_pid" 2>/dev/null || true
  [ -n "$trans_pid" ] && kill "$trans_pid" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

for bin in build/eavt-sql-transactor build/eavt-sql-query build/eavt-sql-cli-go; do
  [ -x "$bin" ] || { echo "missing $bin — run: nimble dist" >&2; exit 1; }
done
if [ ! -x build/eavt-sql-query-front-go ]; then
  (cd go && go build -o ../build/eavt-sql-query-front-go ./cmd/eavt-query-front)
fi

# kill_all + fresh stack with an empty DB.
start_back() {
  [ -n "$front_pid" ] && kill "$front_pid" 2>/dev/null || true
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

norm() { sed -E 's/tx=[0-9]+/tx=<ID>/g; s#socket=[^ ]+#socket=<SOCK>#g'; }

# baseline: Go REPL -> Nim front (eavt-query.sock)
start_back
"$ROOT/build/eavt-sql-cli-go" "$XDG_RUNTIME_DIR/eavt/eavt-query.sock" \
  <"$SESSION" >"$WORK/nimfront.out" 2>&1 || true

# test: Go front on eavt-query-go.sock -> Nim back internal socket
start_back
"$ROOT/build/eavt-sql-query-front-go" \
  --socket-path "$XDG_RUNTIME_DIR/eavt/eavt-query-go.sock" \
  --back-path "$XDG_RUNTIME_DIR/eavt/eavt-query-internal.sock" \
  >"$WORK/front.log" 2>&1 &
front_pid=$!
for _ in $(seq 1 40); do
  [ -S "$XDG_RUNTIME_DIR/eavt/eavt-query-go.sock" ] && break
  sleep 0.25
done
sleep 0.3
"$ROOT/build/eavt-sql-cli-go" "$XDG_RUNTIME_DIR/eavt/eavt-query-go.sock" \
  <"$SESSION" >"$WORK/gofront.out" 2>&1 || true

norm <"$WORK/nimfront.out" >"$WORK/a.norm"
norm <"$WORK/gofront.out" >"$WORK/b.norm"

if diff -u "$WORK/a.norm" "$WORK/b.norm"; then
  echo "FRONT PARITY OK ($(wc -l <"$WORK/a.norm") lines)"
else
  echo "FRONT PARITY DIFF: Nim front and Go front output differ" >&2
  exit 1
fi
