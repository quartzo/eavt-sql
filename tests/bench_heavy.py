"""Heavy performance benchmark — comprehensive workload analysis.

Run: LD_LIBRARY_PATH=target/release uv run python tests/bench_heavy.py
     LD_LIBRARY_PATH=target/release uv run python tests/bench_heavy.py --scale 50000
     LD_LIBRARY_PATH=target/release uv run python tests/bench_heavy.py --backend file --path /tmp/bench_db
"""
import argparse
import os
import statistics
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

DEFAULT_SCALE = 20000


def fmt_ms(seconds):
    return f"{seconds * 1000:.1f}ms"


def fmt_ops(seconds, count):
    return f"{count / seconds:,.0f} ops/s" if seconds > 0 else "inf"


def section(title):
    print(f"\n{'=' * 70}")
    print(f"  {title}")
    print(f"{'=' * 70}")


def timed(label, fn, repeat=1):
    times = []
    result = None
    for _ in range(repeat):
        t0 = time.perf_counter()
        result = fn()
        times.append(time.perf_counter() - t0)
    elapsed = min(times)
    count = len(result) if isinstance(result, (list, tuple)) else result
    extra = f"({count:,} rows)" if isinstance(count, int) and count > 0 else ""
    print(f"  {label:50s} {fmt_ms(elapsed):>10s}  {extra}")
    return elapsed


def timed_n(label, fn, n, repeat=1):
    times = []
    for _ in range(repeat):
        t0 = time.perf_counter()
        fn()
        times.append(time.perf_counter() - t0)
    elapsed = min(times)
    print(f"  {label:50s} {fmt_ms(elapsed):>10s}  {fmt_ops(elapsed, n)}")
    return elapsed


def setup_schema(engine):
    for stmt in [
        "ATTRIBUTE company.name STRING ONE UNIQUE",
        "ATTRIBUTE company.revenue FLOAT ONE",
        "ATTRIBUTE company.active BOOLEAN ONE",
        "ATTRIBUTE company.tags STRING MANY",
        "ATTRIBUTE company.ceo REF ONE",
        "ATTRIBUTE company.hq REF ONE",
        "ATTRIBUTE person.name STRING ONE UNIQUE",
        "ATTRIBUTE person.age LONG ONE",
        "ATTRIBUTE city.name STRING ONE UNIQUE",
        "ATTRIBUTE city.population LONG ONE",
        "ATTRIBUTE item.codigo STRING ONE UNIQUE",
        "ATTRIBUTE item.preco FLOAT ONE",
        "ATTRIBUTE order.total FLOAT ONE",
        "ATTRIBUTE order.item REF ONE",
    ]:
        list(engine.sql(stmt))


def bench_writes(engine, n):
    section(f"BULK WRITES — {n:,} entities")

    t0 = time.perf_counter()
    for i in range(n):
        list(engine.sql(
            "UPSERT AS D1 SET company.name = %1, company.revenue = %2, company.active = true",
            f"company_{i:06d}", float(i * 100),
        ))
    elapsed = time.perf_counter() - t0
    print(f"  {'UPSERT single-entity × N':50s} {fmt_ms(elapsed):>10s}  {fmt_ops(elapsed, n)}")

    t0 = time.perf_counter()
    for i in range(n // 2):
        list(engine.sql(
            "UPSERT AS D1 SET person.name = %1, person.age = %2,"
            "    AS D2 SET city.name = %3, city.population = %4",
            f"person_{i:06d}", 20 + (i % 50),
            f"city_{i:06d}", 100_000 + i,
        ))
    elapsed = time.perf_counter() - t0
    half = n // 2
    print(f"  {'UPSERT 2-entity batch × N/2':50s} {fmt_ms(elapsed):>10s}  {fmt_ops(elapsed, half)}")

    t0 = time.perf_counter()
    for i in range(n // 4):
        list(engine.sql(
            "UPSERT AS D1 SET item.codigo = %1, item.preco = %2, order.total = %3",
            f"ITEM_{i:06d}", float(i) * 1.5, float(i) * 1.5,
        ))
    elapsed = time.perf_counter() - t0
    quarter = n // 4
    print(f"  {'UPSERT 3-attr single-entity × N/4':50s} {fmt_ms(elapsed):>10s}  {fmt_ops(elapsed, quarter)}")

    MANY_TAGS = 3
    t0 = time.perf_counter()
    for i in range(n // 10):
        list(engine.sql(
            "UPSERT AS D1 = %1 SET company.tags = %2",
            1000 + i,
            f"tag_{i % 20}",
        ))
    elapsed = time.perf_counter() - t0
    tenth = n // 10
    print(f"  {'UPSERT cardinality-MANY append × N/10':50s} {fmt_ms(elapsed):>10s}  {fmt_ops(elapsed, tenth)}")


def bench_eid_vs_where(engine, n):
    section("eid() vs WHERE — point lookup comparison")

    lookups = [f"company_{i:06d}" for i in range(0, n, max(1, n // 500))]

    t0 = time.perf_counter()
    for name in lookups:
        list(engine.sql(
            "UPSERT AS D1 = eid('company.name', %1) SET company.active = false", name
        ))
    elapsed_where = time.perf_counter() - t0
    print(f"  {'UPSERT WHERE (legacy)':50s} {fmt_ms(elapsed_where):>10s}  {fmt_ops(elapsed_where, len(lookups))}")

    t0 = time.perf_counter()
    for name in lookups:
        list(engine.sql(
            "UPSERT AS D1 = eid('company.name', %1) SET company.active = true", name
        ))
    elapsed_eid = time.perf_counter() - t0
    print(f"  {'UPSERT = eid() (quoted attr)':50s} {fmt_ms(elapsed_eid):>10s}  {fmt_ops(elapsed_eid, len(lookups))}")

    t0 = time.perf_counter()
    for name in lookups:
        list(engine.sql(
            "UPSERT AS D1 = eid(company.name, %1) SET company.active = true", name
        ))
    elapsed_eid_unq = time.perf_counter() - t0
    print(f"  {'UPSERT = eid() (unquoted attr)':50s} {fmt_ms(elapsed_eid_unq):>10s}  {fmt_ops(elapsed_eid_unq, len(lookups))}")

    t0 = time.perf_counter()
    for name in lookups:
        list(engine.sql(
            "UPSERT AS D1 = eid(%1, %2) SET company.active = false",
            "company.name", name,
        ))
    elapsed_eid_param = time.perf_counter() - t0
    print(f"  {'UPSERT = eid(%N, %N) (both params)':50s} {fmt_ms(elapsed_eid_param):>10s}  {fmt_ops(elapsed_eid_param, len(lookups))}")

    print()
    print(f"  {'Speedup eid() vs WHERE':50s} {elapsed_where / elapsed_eid:>9.2f}x")


def bench_val(engine, n):
    section("val() — EAVT point value lookup")

    item_lookups = [f"ITEM_{i:06d}" for i in range(0, n // 4, max(1, n // 800))]

    t0 = time.perf_counter()
    for codigo in item_lookups:
        list(engine.sql(
            "UPSERT AS D1 SET order.total = val(eid('item.codigo', %1), 'item.preco')",
            codigo,
        ))
    elapsed = time.perf_counter() - t0
    print(f"  {'val(eid(...), attr) — nested lookup':50s} {fmt_ms(elapsed):>10s}  {fmt_ops(elapsed, len(item_lookups))}")

    item_eids = []
    for codigo in item_lookups[:100]:
        rows = list(engine.sql("SELECT d1.eid WHERE d1.item.codigo = %1", codigo))
        if rows:
            item_eids.append(rows[0][0])

    t0 = time.perf_counter()
    for eid in item_eids:
        list(engine.sql(
            "UPSERT AS D1 SET order.total = val(%1, 'item.preco')",
            eid,
        ))
    elapsed = time.perf_counter() - t0
    print(f"  {'val(%N, attr) — param eid':50s} {fmt_ms(elapsed):>10s}  {fmt_ops(elapsed, len(item_eids))}")

    t0 = time.perf_counter()
    for codigo in item_lookups:
        list(engine.sql(
            "UPSERT AS D1 SET order.total = val(eid(item.codigo, %1), item.preco)",
            codigo,
        ))
    elapsed = time.perf_counter() - t0
    print(f"  {'val(eid(...), attr) — unquoted':50s} {fmt_ms(elapsed):>10s}  {fmt_ops(elapsed, len(item_lookups))}")


def bench_selects(engine, n):
    section("SELECT — query patterns at scale")

    sample_eid = list(engine.sql("SELECT d1.eid WHERE d1.company.name = %1", "company_000000"))[0][0]

    timed("SELECT eid point lookup", lambda: list(engine.sql(
        "SELECT d1.company.name WHERE d1.eid = %1", sample_eid
    )), repeat=20)

    timed("SELECT by unique attr (AVET)", lambda: list(engine.sql(
        "SELECT d1.eid WHERE d1.company.name = %1", "company_000050"
    )), repeat=20)

    timed("SELECT full scan", lambda: list(engine.sql(
        "SELECT d1.company.name"
    )), repeat=3)

    mid_eid = list(engine.sql("SELECT d1.eid WHERE d1.company.name = %1", f"company_{n // 4:06d}"))[0][0]
    end_eid = list(engine.sql("SELECT d1.eid WHERE d1.company.name = %1", f"company_{n // 2:06d}"))[0][0]
    timed(f"SELECT range ~25% (by eid)", lambda: list(engine.sql(
        "SELECT d1.company.name WHERE d1.eid >= %1 AND d1.eid < %2",
        mid_eid, end_eid,
    )), repeat=3)

    timed("SELECT many-cardinality (tags)", lambda: list(engine.sql(
        "SELECT d1.company.tags WHERE d1.eid = %1", 1000
    )), repeat=20)

    timed("SELECT wildcard (attr + val)", lambda: list(engine.sql(
        "SELECT d1.attr, d1.val WHERE d1.eid = %1", sample_eid
    )), repeat=20)


def bench_joins(engine, n):
    section("JOIN — multi-pattern queries")

    half = n // 2
    ceo_eid = list(engine.sql("SELECT d1.eid WHERE d1.person.name = %1", "person_000000"))[0][0]
    if ceo_eid:
        list(engine.sql("UPSERT AS D1 = eid('company.name', 'company_000000') SET company.ceo = %1", ceo_eid))

    city_eid = list(engine.sql("SELECT d1.eid WHERE d1.city.name = %1", "city_000000"))[0][0]
    if city_eid:
        list(engine.sql("UPSERT AS D1 = eid('company.name', 'company_000000') SET company.hq = %1", city_eid))

    timed("2-pattern join (company → ceo)", lambda: list(engine.sql(
        "SELECT d1.company.name, d2.person.name"
        " WHERE d1.company.ceo = d2.eid AND d1.company.name = 'company_000000'"
    )), repeat=20)

    timed("2-pattern join (company → hq)", lambda: list(engine.sql(
        "SELECT d1.company.name, d2.city.name"
        " WHERE d1.company.hq = d2.eid AND d1.company.name = 'company_000000'"
    )), repeat=20)

    timed("3-pattern chain (company → ceo → company)", lambda: list(engine.sql(
        "SELECT d1.company.name, d2.person.name, d3.company.name"
        " WHERE d1.company.ceo = d2.eid AND d2.person.name = 'person_000000'"
        " AND d1.company.hq = d3.eid"
    )), repeat=10)

    timed("Reverse lookup (VAET)", lambda: list(engine.sql(
        "SELECT d1.eid WHERE d1.company.ceo = %1", ceo_eid
    )), repeat=20)


def bench_delete(engine, n):
    section("DELETE — retraction performance")

    delete_eids = list(engine.sql("SELECT d1.eid WHERE d1.company.name = %1", "company_000000"))
    if delete_eids:
        sample_eid = delete_eids[0][0]
        list(engine.sql("UPSERT AS D1 = %1 SET company.tags = 'dtag1', company.tags = 'dtag2'", sample_eid))

        t0 = time.perf_counter()
        list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.company.tags = 'dtag1'", sample_eid))
        elapsed = time.perf_counter() - t0
        print(f"  {'DELETE single datom':50s} {fmt_ms(elapsed):>10s}")

    delete_batch = []
    for i in range(n // 10, n // 10 + min(100, n // 10)):
        rows = list(engine.sql("SELECT d1.eid WHERE d1.company.name = %1", f"company_{i:06d}"))
        if rows:
            delete_batch.append(rows[0][0])

    if delete_batch:
        t0 = time.perf_counter()
        for eid in delete_batch:
            list(engine.sql("DELETE WHERE d1.eid = %1 AND d1.company.active = true", eid))
        elapsed = time.perf_counter() - t0
        print(f"  {'DELETE × 100 (conditional)':50s} {fmt_ms(elapsed):>10s}  {fmt_ops(elapsed, len(delete_batch))}")


def bench_mixed_workload(engine, n):
    section("MIXED WORKLOAD — read/write interleaved")

    lookups = [f"company_{i:06d}" for i in range(0, n, max(1, n // 200))]

    t0 = time.perf_counter()
    ops = 0
    for i, name in enumerate(lookups):
        if i % 5 == 0:
            list(engine.sql("UPSERT AS D1 = eid(company.name, %1) SET company.revenue = %2", name, float(i) * 2.5))
            ops += 1
        elif i % 5 == 1:
            list(engine.sql("SELECT d1.company.revenue WHERE d1.company.name = %1", name))
            ops += 1
        elif i % 5 == 2:
            list(engine.sql("SELECT d1.eid, d1.company.active WHERE d1.company.name = %1", name))
            ops += 1
        elif i % 5 == 3:
            list(engine.sql("DELETE WHERE d1.company.name = %1 AND d1.company.tags = 'nonexist'", name))
            ops += 1
        else:
            list(engine.sql("SELECT d1.company.tags WHERE d1.company.name = %1", name))
            ops += 1
    elapsed = time.perf_counter() - t0
    print(f"  {'Mixed (20% write, 80% read)':50s} {fmt_ms(elapsed):>10s}  {fmt_ops(elapsed, ops)}")


def bench_flush_impact(engine, n):
    section("FLUSH — MemTable → PageStore")

    timed("SELECT before flush (MemTable)", lambda: list(engine.sql(
        "SELECT d1.company.name"
    )), repeat=3)

    t0 = time.perf_counter()
    engine.flush()
    elapsed = time.perf_counter() - t0
    print(f"  {'flush()':50s} {fmt_ms(elapsed):>10s}")

    timed("SELECT after flush (PageStore)", lambda: list(engine.sql(
        "SELECT d1.company.name"
    )), repeat=3)

    timed("Point lookup after flush", lambda: list(engine.sql(
        "SELECT d1.eid WHERE d1.company.name = %1", "company_000050"
    )), repeat=20)

    timed("eid() after flush", lambda: list(engine.sql(
        "UPSERT AS D1 = eid(company.name, %1) SET company.active = true", "company_000050"
    )), repeat=20)


def main():
    parser = argparse.ArgumentParser(description="EAVT heavy performance benchmark")
    parser.add_argument("--scale", type=int, default=DEFAULT_SCALE, help=f"Number of entities (default: {DEFAULT_SCALE})")
    parser.add_argument("--backend", choices=["memory", "file"], default="memory", help="Storage backend")
    parser.add_argument("--path", type=str, default="/tmp/eavt_bench", help="Path for file backend")
    parser.add_argument("--sections", type=str, default="all", help="Comma-separated sections to run (all,writes,eid,val,selects,joins,delete,mixed,flush)")
    parser.add_argument("--cache-size", type=int, default=None, help="Page cache size in bytes (default: 64MB)")
    args = parser.parse_args()

    n = args.scale
    sections = args.sections.split(",") if args.sections != "all" else ["all"]

    cache_label = f"{args.cache_size / 1024 / 1024:.0f}MB" if args.cache_size is not None else "default(64MB)"
    print(f"\n{'#' * 70}")
    print(f"  EAVT HEAVY PERFORMANCE BENCHMARK")
    print(f"  Scale: {n:,} entities  |  Backend: {args.backend}  |  Cache: {cache_label}")
    print(f"{'#' * 70}")

    if args.backend == "file":
        import shutil
        shutil.rmtree(args.path, ignore_errors=True)
        engine = EAVTEngine(args.path, page_cache_size=args.cache_size)
    else:
        engine = EAVTEngine(":memory:", page_cache_size=args.cache_size)

    setup_schema(engine)
    print(f"\n  Schema declared. Loading {n:,} entities...")

    # Always seed data (writes section also measures)
    bench_writes(engine, n)

    def run(name, fn):
        if "all" in sections or name in sections:
            fn(engine, n)

    run("eid", bench_eid_vs_where)
    run("val", bench_val)
    run("selects", bench_selects)
    run("joins", bench_joins)
    run("delete", bench_delete)
    run("mixed", bench_mixed_workload)
    run("flush", bench_flush_impact)

    engine.close()

    if args.backend == "file":
        import shutil
        db_size = sum(f.stat().st_size for f in Path(args.path).rglob("*") if f.is_file())
        print(f"\n  Disk usage: {db_size / 1024 / 1024:.1f} MB")

    section("BENCHMARK COMPLETE")


if __name__ == "__main__":
    main()
