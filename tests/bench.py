"""Performance benchmarks — measures insert/query/flush latency.

Run: LD_LIBRARY_PATH=target/release uv run python tests/bench.py
"""
import time
import sys
import os
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
_release = _root / "target" / "release"
os.environ.setdefault("DYNSPIRE_LIB_DIR", str(_release))
_lp = os.environ.get("LD_LIBRARY_PATH", "")
if str(_release) not in _lp:
    os.environ["LD_LIBRARY_PATH"] = f"{_release}:{_lp}" if _lp else str(_release)
sys.path.insert(0, str(_root / "src"))

from eavt_sql.engine import EAVTEngine


def bench(label, fn, iterations=1):
    times = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        result = fn()
        times.append(time.perf_counter() - t0)
    avg = sum(times) / len(times) * 1000
    best = min(times) * 1000
    count = len(result) if isinstance(result, (list, tuple)) else result
    print(f"  {label:40s} {avg:8.1f}ms avg  {best:8.1f}ms best  ({count} results)")
    return result


def main():
    print("=== EAVT Performance Benchmark ===\n")

    for n in [100, 1000, 5000]:
        print(f"--- {n} entities ---")
        engine = EAVTEngine(":memory:")

        list(engine.sql("ATTRIBUTE bench.name STRING ONE"))
        list(engine.sql("ATTRIBUTE bench.value LONG ONE"))

        # Insert N entities
        t0 = time.perf_counter()
        for i in range(n):
            list(engine.sql("UPSERT SET bench.name = %1, bench.value = %2", f"entity_{i}", i))
        elapsed = (time.perf_counter() - t0) * 1000
        per_op = elapsed / n
        print(f"  {'INSERT (UPSERT × N)':40s} {elapsed:8.1f}ms total {per_op:6.3f}ms/op")

        # Get all eids
        all_rows = list(engine.sql("SELECT d1.bench.name"))
        assert len(all_rows) == n, f"Expected {n}, got {len(all_rows)}"

        eid = list(engine.sql("UPSERT SET bench.name = %1", "test_entity"))[0][0]

        bench("SELECT by eid", lambda: list(engine.sql("SELECT d1.bench.name WHERE d1.eid = %1", eid)), 10)

        bench("SELECT by attr value", lambda: list(engine.sql("SELECT d1.bench.name WHERE d1.bench.value = %1", n // 2)), 10)

        bench("SELECT all names", lambda: list(engine.sql("SELECT d1.bench.name")), 3)

        bench("SELECT range (25%)", lambda: list(engine.sql(
            "SELECT d1.bench.name WHERE d1.bench.value >= %1 AND d1.bench.value < %2",
            n // 4, n // 2,
        )), 3)

        # JOIN test
        list(engine.sql("ATTRIBUTE bench.target REF ONE"))
        first_eid = list(engine.sql("SELECT d1.eid WHERE d1.bench.name = %1", "entity_0"))[0][0]
        step = max(1, n // 100)
        for i in range(0, n, step):
            eid_i = list(engine.sql("SELECT d1.eid WHERE d1.bench.name = %1", f"entity_{i}"))[0][0]
            list(engine.sql("UPSERT AS D1 = %1 SET bench.target = %2", eid_i, first_eid))

        bench("JOIN (~1% have ref)", lambda: list(engine.sql(
            "SELECT d1.bench.name, d2.bench.name WHERE d1.bench.target = d2.eid",
        )), 3)

        # After flush
        engine.flush()
        bench("SELECT after flush", lambda: list(engine.sql("SELECT d1.bench.name")), 3)

        engine.close()
        print()

    print("=== Done ===")


if __name__ == "__main__":
    main()
