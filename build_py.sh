#!/usr/bin/env bash
# Rebuild PyO3 bindings in the venv via maturin develop (editable, no wheels).
# Run this after changing Rust code that affects the Python bindings.
#
# Usage:
#   ./build_py.sh              # rebuild all 4 bindings
#   ./build_py.sh eavt         # rebuild only spier-eavt-query-py (fuzzy match)
set -euo pipefail

cd "$(dirname "$0")"
CRATES=(spier-sql-parse-py spier-eavt-query-py)

if [ $# -gt 0 ]; then
    FILTER="$1"
    CRATES=("${CRATES[@]/#$FILTER/}")
    CRATES=($(printf '%s\n' "${CRATES[@]}" | rg "$FILTER" || true))
    if [ ${#CRATES[@]} -eq 0 ]; then
        echo "No crate matching '$FILTER'. Available: spier-sql-parse-py spier-eavt-query-py"
        exit 1
    fi
fi

for crate in "${CRATES[@]}"; do
    echo "=== $crate ==="
    uv run maturin develop --release --manifest-path "$crate/Cargo.toml"
done
