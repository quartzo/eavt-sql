"""Performance benchmarks — measures insert/query/flush latency via public API.

Run:  uv run python tests/bench_py.py
"""
import time
import sys
import tempfile
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_root / "py_eavt" / "src"))
from eavt import EavtEngine, QuerySession, prepare


def bench(label, fn, iterations=1):
    times = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        result = fn()
        times.append(time.perf_counter() - t0)
    avg = sum(times) / len(times) * 1000
    best = min(times) * 1000
    if isinstance(result, (list, tuple)):
        count = len(result)
    elif result is None:
        count = 0
    else:
        count = 1
    print(f"  {label:40s} {avg:8.1f}ms avg  {best:8.1f}ms best  ({count} results)")
    return result


def main():
    print("=== EAVT In-Process Performance Benchmark (public API) ===\n")

    for n in [100, 1000, 5000]:
        print(f"--- {n} entities ---")
        with tempfile.TemporaryDirectory() as tmpdir:
            eng = EavtEngine(tmpdir)
            eng.bootstrap()
            sess = QuerySession(eng)
            sess.declare_attr("bench.name", "string")
            sess.declare_attr("bench.value", "long")

            # INSERT N entities
            eids = []
            t0 = time.perf_counter()
            for i in range(n):
                eid = sess.alloc_entity()
                sess.save(eid, "bench.name", f"entity_{i}")
                sess.save(eid, "bench.value", i)
                eids.append(eid)
            sess.commit()
            elapsed = (time.perf_counter() - t0) * 1000
            per_op = elapsed / n
            print(f"  {'INSERT (save x N)':40s} {elapsed:8.1f}ms total {per_op:6.3f}ms/op")

            # SELECT all names (AEVT scan)
            q_all = prepare(sess, ["?name"],
                            [("_", "bench.name", "?name")])
            rows = bench("SELECT all names", lambda: list(q_all.execute()), 3)
            assert len(rows) == n, f"Expected {n}, got {len(rows)}"

            # SELECT by eid (EAVT lookup)
            test_eid = eids[0]
            q_eid = prepare(sess, ["?name"],
                            [(test_eid, "bench.name", "?name")])
            bench("SELECT by eid", lambda: list(q_eid.execute()), 10)

            # SELECT by attr value (AVET lookup)
            q_val = prepare(sess, ["?eid"],
                            [("?eid", "bench.value", n // 2)])
            bench("SELECT by attr value", lambda: list(q_val.execute()), 10)

            # SELECT all names again
            bench("SELECT all names (2nd)", lambda: list(q_all.execute()), 3)

            # Range query: value >= n//4 and value < n//2
            q_range = prepare(sess, ["?eid", "?val"],
                              [("?eid", "bench.value", "?val")],
                              ranges={"?val": (">=", n // 4, "<", n // 2)})
            rows_range = bench("SELECT range (25%)", lambda: list(q_range.execute()), 3)

            # JOIN: ~1% of entities have bench.target = first_eid
            sess.declare_attr("bench.target", "ref")
            first_eid = eids[0]
            step = max(1, n // 100)
            for i in range(0, n, step):
                sess.save(eids[i], "bench.target", first_eid)
            sess.commit()

            q_join = prepare(sess, ["?eid1", "?eid2", "?name1", "?name2"], [
                ("?eid1", "bench.target", "?eid2"),
                ("?eid1", "bench.name",  "?name1"),
                ("?eid2", "bench.name",  "?name2"),
            ])
            bench("JOIN (~1% have ref)", lambda: list(q_join.execute()), 3)

            # After flush
            sess.commit(sync=True)
            bench("SELECT after flush", lambda: list(q_all.execute()), 3)

            eng.close()
        print()

    print("=== Done ===")


if __name__ == "__main__":
    main()
