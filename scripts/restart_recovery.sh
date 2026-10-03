#!/usr/bin/env bash
# restart_recovery.sh — durability/recovery test for the Go stack:
#   boot → schema + Alice + flush-sync → Bob (unflushed) → kill -9 →
#   reboot → query must return Alice (page store) AND Bob (WAL replay).
# Also asserts the bootstrap datoms go through the WAL segments (no legacy
# `journal` file) and that unflushed writes survive a process crash.
#
# Requires: build/eavt-sql-{transactor-go,query-go,cli-go}.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
WORK="$(mktemp -d /tmp/eavt-recovery.XXXXXX)"
export XDG_RUNTIME_DIR="$WORK/run"
export XDG_DATA_HOME="$WORK/data"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME"

TPID=""
QPID=""
cleanup() {
  [ -n "$QPID" ] && kill -9 "$QPID" 2>/dev/null || true
  [ -n "$TPID" ] && kill -9 "$TPID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

for bin in build/eavt-sql-transactor-go build/eavt-sql-query-go build/eavt-sql-cli-go; do
  [ -x "$bin" ] || { echo "missing $bin — run: nimble dist" >&2; exit 1; }
done

SOCK="$XDG_RUNTIME_DIR/eavt/eavt-query.sock"
CLI="$ROOT/build/eavt-sql-cli-go"

start() {
  "$ROOT/build/eavt-sql-transactor-go" </dev/null >"$WORK/trans.log" 2>&1 &
  TPID=$!
  for _ in $(seq 1 80); do [ -S "$XDG_RUNTIME_DIR/eavt/eavt-transactor.sock" ] && break; sleep 0.25; done
  sleep 0.3
  "$ROOT/build/eavt-sql-query-go" </dev/null >"$WORK/query.log" 2>&1 &
  QPID=$!
  for _ in $(seq 1 80); do [ -S "$SOCK" ] && break; sleep 0.25; done
  sleep 0.6
}
crash() { kill -9 "$QPID" "$TPID" 2>/dev/null || true; wait 2>/dev/null || true; TPID=""; QPID=""; }

# first boot
start
printf '%s\n' \
  '[[:db/add 0 :db/ident :person/name] [:db/add 0 :db/valueType :db.type/string] [:db/add 0 :db/cardinality :db.cardinality/one]]' \
  '[[:db/add -1 :person/name "Alice"]]' \
  '.flush-sync' \
  '[[:db/add -2 :person/name "Bob"]]' \
  | "$CLI" "$SOCK" >/dev/null 2>&1
crash

# bootstrap datoms must be in WAL segments, not a legacy journal file.
if [ -f "$XDG_DATA_HOME/eavt/db/journal/journal" ]; then
  echo "RECOVERY FAIL: legacy journal file was written (bootstrap bypassed the WAL)" >&2
  exit 1
fi

# second boot on the same data dir
start
out=$("$CLI" "$SOCK" <<'EOF' 2>&1
[:find ?n :where [?e :person/name ?n]]
EOF
)
crash

if echo "$out" | grep -q Alice && echo "$out" | grep -q Bob; then
  echo "RECOVERY OK (Alice flushed + Bob from WAL replay)"
else
  echo "RECOVERY FAIL" >&2
  echo "$out" >&2
  exit 1
fi
