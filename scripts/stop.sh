#!/usr/bin/env bash
# stop.sh — Kill running EAVT servers and clean up sockets.
set -euo pipefail
cd "$(dirname "$0")/.."

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK_DIR="$XDG_RUNTIME_DIR/eavt"

# Kill by the process's ACTUAL executable (/proc/pid/exe), not by cmdline
# substring — `pgrep -f "build/eavt-sql-transactor"` also matches innocent
# processes whose command line merely CONTAINS the path (editors, greps,
# compiler invocations like `nim c -o:build/eavt-sql-transactor ...`), which
# made this script kill the caller's own shell.
declare -a term_pids=() kill_pids=()
for pid in $(pgrep -f eavt-sql || true); do
  [ "$pid" = "$$" ] && continue
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
  case "$exe" in
    */build/eavt-sql-transactor|*/build/eavt-sql-query)
      term_pids+=("$pid")
      echo "killing $exe (pid $pid)"
      ;;
  esac
done

if [ ${#term_pids[@]} -gt 0 ]; then
  printf '%s\n' "${term_pids[@]}" | xargs -r kill 2>/dev/null || true
  sleep 0.3
  printf '%s\n' "${term_pids[@]}" | xargs -r kill -9 2>/dev/null || true
fi

# Clean up sockets
rm -f "$SOCK_DIR/eavt-query.sock" "$SOCK_DIR/eavt-transactor.sock" 2>/dev/null || true
echo "stopped"
