"""Performance benchmarks — measures insert/query/flush latency in-process (py_eavt).

Run:  uv run python tests/bench_py.py
"""
import time
import sys
import tempfile
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_root / "py_eavt" / "src"))
from eavt.engine import EavtEngine
from eavt import keys
from eavt.keys import encode_int, encode_string, _U64
from eavt.types import DB_TYPE_LONG


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


def _aid_prefix(aid: int) -> bytes:
    return aid.to_bytes(4, "big")


def _is_retracted(key: bytes) -> bool:
    return (key[-1] & 1) != 0


def scan_aevt_values(eng, attr_name):
    """Return list of (eid, value) for all active datoms of attr (AEVT scan)."""
    aid = eng.lookup_attr(attr_name)
    vt = eng.value_type_for(aid)
    results = []
    for key in eng.scan_prefix(1, _aid_prefix(aid)):
        if len(key) < 20 or _is_retracted(key):
            continue
        eid, _ = keys.decode_value_at(key, 4, DB_TYPE_LONG)
        val, _ = keys.decode_value_at(key, 12, vt or 20)
        results.append((eid, val))
    return results


def scan_avet_lookup(eng, attr_name, value):
    """Return list of eids where attr=value (AVET lookup)."""
    aid = eng.lookup_attr(attr_name)
    vt = eng.value_type_for(aid)
    if vt == 20:
        val_enc = encode_string(str(value))
    else:
        val_enc = encode_int(int(value))
    prefix = _aid_prefix(aid) + val_enc
    results = []
    for key in eng.scan_prefix(2, prefix):
        if len(key) < 16 or _is_retracted(key):
            continue
        eid, _ = keys.decode_value_at(key, len(key) - keys._SUFFIX_SIZE - 8, DB_TYPE_LONG)
        results.append(eid)
    return results


def scan_eavt_by_eid(eng, eid, attr_name):
    """Return value of attr for eid (EAVT lookup)."""
    aid = eng.lookup_attr(attr_name)
    vt = eng.value_type_for(aid)
    prefix = encode_int(eid) + _aid_prefix(aid)
    for key in eng.scan_prefix(0, prefix):
        if len(key) < 20 or _is_retracted(key):
            continue
        val, _ = keys.decode_value_at(key, 12, vt or 20)
        return val
    return None


def main():
    print("=== EAVT In-Process Performance Benchmark ===\n")

    for n in [100, 1000, 5000]:
        print(f"--- {n} entities ---")
        with tempfile.TemporaryDirectory() as tmpdir:
            eng = EavtEngine(tmpdir)

            eng.declare_attr("bench.name", "STRING", False)
            eng.declare_attr("bench.value", "LONG", False)

            # Insert N entities
            eids = []
            t0 = time.perf_counter()
            for i in range(n):
                eid = eng.alloc_entity()
                eng.save(eid, "bench.name", f"entity_{i}")
                eng.save(eid, "bench.value", i)
                eids.append(eid)
            eng.commit()
            elapsed = (time.perf_counter() - t0) * 1000
            per_op = elapsed / n
            print(f"  {'INSERT (save × N)':40s} {elapsed:8.1f}ms total {per_op:6.3f}ms/op")

            # Get all names (AEVT scan)
            all_names = bench("SELECT all names (AEVT)",
                lambda: scan_aevt_values(eng, "bench.name"), 3)
            assert len(all_names) == n, f"Expected {n}, got {len(all_names)}"

            test_eid = eids[0]

            bench("SELECT by eid (EAVT)", lambda: scan_eavt_by_eid(eng, test_eid, "bench.name"), 10)

            bench("SELECT by attr value (AVET)",
                lambda: scan_avet_lookup(eng, "bench.value", n // 2), 10)

            bench("SELECT all names (AEVT)", lambda: scan_aevt_values(eng, "bench.name"), 3)

            # Range query: value >= n//4 and value < n//2
            def range_query():
                results = []
                for eid, val in scan_aevt_values(eng, "bench.value"):
                    if n // 4 <= val < n // 2:
                        results.append((eid, val))
                return results
            bench("SELECT range (25%)", range_query, 3)

            # JOIN: ~1% of entities have bench.target = first_eid
            eng.declare_attr("bench.target", "REF", False)
            first_eid = eids[0]
            step = max(1, n // 100)
            for i in range(0, n, step):
                eng.save(eids[i], "bench.target", first_eid)
            eng.commit()

            def join_query():
                results = []
                for eid, _ in scan_aevt_values(eng, "bench.target"):
                    name1 = scan_eavt_by_eid(eng, eid, "bench.name")
                    name2 = scan_eavt_by_eid(eng, first_eid, "bench.name")
                    if name1 and name2:
                        results.append((name1, name2))
                return results
            bench("JOIN (~1% have ref)", join_query, 3)

            # After flush (commit with sync)
            eng.commit(sync=True)
            bench("SELECT after flush", lambda: scan_aevt_values(eng, "bench.name"), 3)

            eng.close()
        print()

    print("=== Done ===")


if __name__ == "__main__":
    main()
