"""Performance benchmarks — measures insert/query/flush latency via UDS.

Run:  ./eavt_server_nim/server &
      uv run python tests/bench.py
"""
import time
import subprocess
import sys
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_root / "py_eavt_client" / "src"))
from eavt_client.client import EavtClient

SERVER_BIN = _root / "eavt_server_nim" / "server"


def ensure_server():
    """Start eavt_server_nim if not already running."""
    import socket
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(str(EavtClient._default_path()))
        s.close()
        return  # already running
    except Exception:
        pass
    return subprocess.Popen([str(SERVER_BIN)], stdout=subprocess.DEVNULL)


def bench(client, label, fn, iterations=1):
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


def sql(client, query, *params):
    return client.execute(query, *params)


def main():
    print("=== EAVT Performance Benchmark ===\n")
    server = ensure_server()

    for n in [100, 1000, 5000]:
        print(f"--- {n} entities ---")
        client = EavtClient()

        sql(client, "ATTRIBUTE bench.name STRING ONE")
        sql(client, "ATTRIBUTE bench.value LONG ONE")

        # Insert N entities
        t0 = time.perf_counter()
        for i in range(n):
            sql(client, "UPSERT SET bench.name = %1, bench.value = %2", f"entity_{i}", str(i))
        elapsed = (time.perf_counter() - t0) * 1000
        per_op = elapsed / n
        print(f"  {'INSERT (UPSERT × N)':40s} {elapsed:8.1f}ms total {per_op:6.3f}ms/op")

        # Get all names
        all_rows = sql(client, "SELECT d1.bench.name")
        assert len(all_rows) == n, f"Expected {n}, got {len(all_rows)}"

        eid_rows = sql(client, "UPSERT SET bench.name = %1", "test_entity")
        eid = eid_rows[0][0] if eid_rows else 0

        bench(client, "SELECT by eid", lambda: sql(client, "SELECT d1.bench.name WHERE d1.eid = %1", str(eid)), 10)

        bench(client, "SELECT by attr value", lambda: sql(client, "SELECT d1.bench.name WHERE d1.bench.value = %1", str(n // 2)), 10)

        bench(client, "SELECT all names", lambda: sql(client, "SELECT d1.bench.name"), 3)

        bench(client, "SELECT range (25%)", lambda: sql(client,
            "SELECT d1.bench.name WHERE d1.bench.value >= %1 AND d1.bench.value < %2",
            str(n // 4), str(n // 2)), 3)

        # JOIN test
        sql(client, "ATTRIBUTE bench.target REF ONE")
        first = sql(client, "SELECT d1.eid WHERE d1.bench.name = %1", "entity_0")
        first_eid = str(first[0][0]) if first else "0"
        step = max(1, n // 100)
        for i in range(0, n, step):
            r = sql(client, "SELECT d1.eid WHERE d1.bench.name = %1", f"entity_{i}")
            if r:
                sql(client, "UPSERT AS D1 = %1 SET bench.target = %2", str(r[0][0]), first_eid)

        bench(client, "JOIN (~1% have ref)", lambda: sql(client,
            "SELECT d1.bench.name, d2.bench.name WHERE d1.bench.target = d2.eid"), 3)

        # After flush
        client.admin("flush")
        bench(client, "SELECT after flush", lambda: sql(client, "SELECT d1.bench.name"), 3)

        client.close()
        print()

    if server:
        server.terminate()
        server.wait()
    print("=== Done ===")


if __name__ == "__main__":
    main()
