#!/usr/bin/env bash
# Run Python tests. Requires PyO3 bindings built via ./build_py.sh.
# Usage: ./run_tests.sh [-v] [pytest args...]
set -euo pipefail
exec uv run pytest tests/ "$@"
