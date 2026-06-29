"""Benchmark: compile cost vs execution cost isolation.

Demonstrates the value of PreparedStatement (compile once, execute many)
vs raw engine.sql() (recompile every call).

Run: LD_LIBRARY_PATH=target/release uv run python tests/bench_compile_vs_exec.py
     LD_LIBRARY_PATH=target/release uv run python tests/bench_compile_vs_exec.py --scale 50000
"""
import argparse
import os
import sys
import time
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
_release = _root / "target" / "release"
os.environ.setdefault("DYNSPIRE_LIB_DIR", str(_release))
_lp = os.environ.get("LD_LIBRARY_PATH", "")
if str(_release) not in _lp:
    os.environ["LD_LIBRARY_PATH"] = f"{_release}:{_lp}" if _lp else str(_release)
sys.path.insert(0, str(_root / "src"))

from eavt_sql.engine import EAVTEngine


def fmt_ms(seconds):
    return f"{seconds * 1000:.1f}ms"


def fmt_us(seconds):
    return f"{seconds * 1e6:.1f}us"


def section(title):
    print(f"\n{'=' * 70}")
    print(f"  {title}")
    print(f"{'=' * 70}")


def setup(engine, n):
    list(engine.sql("ATTRIBUTE company.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE company.revenue FLOAT ONE"))
    list(engine.sql("ATTRIBUTE company.active BOOLEAN ONE"))
    list(engine.sql("ATTRIBUTE person.name STRING ONE UNIQUE"))
    list(engine.sql("ATTRIBUTE person.age LONG ONE"))

    t0 = time.perf_counter()
    for i in range(n):
        list(engine.sql(
            "UPSERT AS D1 SET company.name = %1, company.revenue = %2",
            f"company_{i:06d}", float(i * 100),
        ))
    for i in range(n // 2):
        list(engine.sql(
            "UPSERT AS D1 SET person.name = %1, person.age = %2",
            f"person_{i:06d}", 20 + (i % 50),
        ))
    elapsed = time.perf_counter() - t0
    print(f"  Seeded {n + n // 2:,} entities in {fmt_ms(elapsed)}")
    for _ in range(10):
        try:
            engine.flush()
            break
        except RuntimeError:
            time.sleep(0.1)
    print(f"  Flushed to PageStore")


def bench_compile_cost(engine, n):
    section("COMPILE COST — how long does it take to compile?")

    queries = [
        ("SELECT full scan", "SELECT d1.company.name"),
        ("SELECT point lookup", "SELECT d1.eid WHERE d1.company.name = %1"),
        ("SELECT 2-attr", "SELECT d1.company.name, d1.company.revenue WHERE d1.eid = %1"),
        ("SELECT range", "SELECT d1.company.name WHERE d1.eid >= %1 AND d1.eid < %2"),
        ("UPSERT", "UPSERT AS D1 SET company.name = %1, company.revenue = %2"),
        ("eid() lookup", "UPSERT AS D1 = eid(company.name, %1) SET company.revenue = %2"),
    ]

    iters = 500
    for label, sql in queries:
        t0 = time.perf_counter()
        for _ in range(iters):
            engine.prepare(sql).close()
        elapsed = time.perf_counter() - t0
        per = elapsed / iters
        print(f"  {label:40s} {fmt_us(per):>10s}/compile  ({iters}x)")


def bench_point_lookup(engine, n):
    section("POINT LOOKUP — raw sql() vs PreparedStatement")

    lookups = [f"company_{i:06d}" for i in range(0, n, max(1, n // 1000))]

    # Raw sql() — recompiles every time
    t0 = time.perf_counter()
    for name in lookups:
        list(engine.sql("SELECT d1.eid WHERE d1.company.name = %1", name))
    elapsed_raw = time.perf_counter() - t0

    # PreparedStatement — compile once
    stmt = engine.prepare("SELECT d1.eid WHERE d1.company.name = %1")
    t0 = time.perf_counter()
    for name in lookups:
        list(stmt.execute(name))
    elapsed_prep = time.perf_counter() - t0
    stmt.close()

    per_raw = elapsed_raw / len(lookups)
    per_prep = elapsed_prep / len(lookups)
    speedup = elapsed_raw / elapsed_prep
    print(f"  {'engine.sql() (compile+exec)':40s} {fmt_us(per_raw):>10s}/op  ({len(lookups):,} ops)")
    print(f"  {'PreparedStatement (exec only)':40s} {fmt_us(per_prep):>10s}/op  ({len(lookups):,} ops)")
    print(f"  {'Speedup':40s} {speedup:>9.1f}x")
    print(f"  {'Compile overhead per call':40s} {fmt_us(per_raw - per_prep):>10s}")


def bench_full_scan(engine, n):
    section("FULL SCAN — compile vs execution")

    iters = 10

    # Raw sql()
    t0 = time.perf_counter()
    for _ in range(iters):
        rows = list(engine.sql("SELECT d1.company.name"))
    elapsed_raw = (time.perf_counter() - t0) / iters

    # PreparedStatement
    stmt = engine.prepare("SELECT d1.company.name")
    t0 = time.perf_counter()
    for _ in range(iters):
        rows = list(stmt.execute())
    elapsed_prep = (time.perf_counter() - t0) / iters
    stmt.close()

    print(f"  {'engine.sql() (compile+exec)':40s} {fmt_ms(elapsed_raw):>10s}  ({len(rows):,} rows)")
    print(f"  {'PreparedStatement (exec only)':40s} {fmt_ms(elapsed_prep):>10s}  ({len(rows):,} rows)")
    print(f"  {'Compile overhead':40s} {fmt_ms(elapsed_raw - elapsed_prep):>10s}")
    print(f"  {'Compile fraction':40s} {(elapsed_raw - elapsed_prep) / elapsed_raw * 100:>9.1f}%")


def bench_upsert(engine, n):
    section("UPSERT — compile vs execution")

    lookups = [(f"company_{i:06d}", float(i * 200)) for i in range(0, n, max(1, n // 1000))]

    # Raw sql()
    t0 = time.perf_counter()
    for name, rev in lookups:
        list(engine.sql("UPSERT AS D1 = eid(company.name, %1) SET company.revenue = %2", name, rev))
    elapsed_raw = time.perf_counter() - t0

    # PreparedStatement
    stmt = engine.prepare("UPSERT AS D1 = eid(company.name, %1) SET company.revenue = %2")
    t0 = time.perf_counter()
    for name, rev in lookups:
        list(stmt.execute(name, rev))
    elapsed_prep = time.perf_counter() - t0
    stmt.close()

    per_raw = elapsed_raw / len(lookups)
    per_prep = elapsed_prep / len(lookups)
    speedup = elapsed_raw / elapsed_prep
    print(f"  {'engine.sql() (compile+exec)':40s} {fmt_us(per_raw):>10s}/op  ({len(lookups):,} ops)")
    print(f"  {'PreparedStatement (exec only)':40s} {fmt_us(per_prep):>10s}/op  ({len(lookups):,} ops)")
    print(f"  {'Speedup':40s} {speedup:>9.1f}x")
    print(f"  {'Compile overhead per call':40s} {fmt_us(per_raw - per_prep):>10s}")


def bench_mixed_workload(engine, n):
    section("MIXED WORKLOAD — raw vs PreparedStatement")

    lookups = [f"company_{i:06d}" for i in range(0, n, max(1, n // 500))]

    queries_raw = [
        "SELECT d1.company.name WHERE d1.company.name = %1",
        "SELECT d1.company.revenue WHERE d1.company.name = %1",
        "SELECT d1.eid, d1.company.revenue WHERE d1.company.name = %1",
        "UPSERT AS D1 = eid(company.name, %1) SET company.revenue = %2",
        "SELECT d1.company.active WHERE d1.company.name = %1",
    ]
    queries_prep = [engine.prepare(q) for q in queries_raw]

    # Raw
    t0 = time.perf_counter()
    ops = 0
    for i, name in enumerate(lookups):
        q = queries_raw[i % len(queries_raw)]
        if "UPSERT" in q:
            list(engine.sql(q, name, float(i) * 2.5))
        else:
            list(engine.sql(q, name))
        ops += 1
    elapsed_raw = time.perf_counter() - t0

    # PreparedStatement
    t0 = time.perf_counter()
    for i, name in enumerate(lookups):
        q = queries_prep[i % len(queries_prep)]
        if "UPSERT" in queries_raw[i % len(queries_raw)]:
            list(q.execute(name, float(i) * 2.5))
        else:
            list(q.execute(name))
    elapsed_prep = time.perf_counter() - t0

    for q in queries_prep:
        q.close()

    per_raw = elapsed_raw / ops
    per_prep = elapsed_prep / ops
    speedup = elapsed_raw / elapsed_prep
    print(f"  {'engine.sql() (compile+exec)':40s} {fmt_us(per_raw):>10s}/op  ({ops:,} ops)")
    print(f"  {'PreparedStatement (exec only)':40s} {fmt_us(per_prep):>10s}/op  ({ops:,} ops)")
    print(f"  {'Speedup':40s} {speedup:>9.1f}x")
    print(f"  {'Compile fraction':40s} {(elapsed_raw - elapsed_prep) / elapsed_raw * 100:>9.1f}%")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scale", type=int, default=20000)
    args = parser.parse_args()
    n = args.scale

    print(f"\n{'#' * 70}")
    print(f"  COMPILE vs EXECUTION BENCHMARK")
    print(f"  Scale: {n:,} entities")
    print(f"{'#' * 70}")

    engine = EAVTEngine(":memory:")
    setup(engine, n)

    bench_compile_cost(engine, n)
    bench_point_lookup(engine, n)
    bench_full_scan(engine, n)
    bench_upsert(engine, n)
    bench_mixed_workload(engine, n)

    engine.close()
    section("BENCHMARK COMPLETE")


if __name__ == "__main__":
    main()
