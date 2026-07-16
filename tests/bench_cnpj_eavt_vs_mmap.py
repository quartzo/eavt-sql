"""Benchmark comparativo: EAVT (gRPC PreparedStatement) vs CnpjSequencialMemory.

Compara representação de relações rowid <-> CNPJ em duas arquiteturas:
- EAVT: 2 atributos únicos (cnpj.cnpj12 STRING + cnpj.rowid LONG) por entidade
- mmap: CnpjSequencialMemory (índice sorted + seq_to_idx + sample_table)

Métricas coletadas por escala N:
- Tempo de ingest + throughput (ops/s)
- Bytes em disco (após flush)
- RAM pico
- Latência p95 de lookup CNPJ -> rowid e rowid -> CNPJ
- Latência de range query (10K CNPJs)

Uso:
    uv run python tests/bench_cnpj_eavt_vs_mmap.py
    uv run python tests/bench_cnpj_eavt_vs_mmap.py --steps 100000 1000000
    uv run python tests/bench_cnpj_eavt_vs_mmap.py --steps 100000 --csv /path/to/cnpjs.csv.gz
"""
import argparse
import gzip
import os
import resource
import shutil
import signal
import statistics
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
_release = _root / "target" / "release"
_lp = os.environ.get("LD_LIBRARY_PATH", "")
if str(_release) not in _lp:
    os.environ["LD_LIBRARY_PATH"] = f"{_release}:{_lp}" if _lp else str(_release)
sys.path.insert(0, str(_root / "py_eavt_client" / "src"))

_dagster_flows = Path("/home/fabio/dev/dagster_flows")
if _dagster_flows.exists():
    sys.path.insert(0, str(_dagster_flows))

from eavt_client.client import EavtClient
from eavt_client import eavt_pb2 as pb

CSV_DEFAULT = "/home/fabio/dev/dagster_flows/tests_data/cnpjs_sequenciais.csv.gz"
DB_ROOT = _root / "bench_data"
SERVER_ADDR = "127.0.0.1:50052"
U64_MAX = 0xFFFFFFFFFFFFFFFF
LOOKUP_SAMPLES = 1000
RANGE_SIZE = 10_000


@dataclass
class BenchResult:
    backend: str
    n: int
    ingest_s: float
    throughput_ops_s: float
    disk_bytes: int
    ram_peak_kb: int
    cnpj_to_rowid_p95_us: float
    rowid_to_cnpj_p95_us: float
    range_10k_ms: float
    extra: dict = field(default_factory=dict)


def load_cnpj_source(n: int, csv_path: str) -> list[str]:
    """Lê primeiros N CNPJs do CSV (formato: sequencia,cnpj)."""
    out: list[str] = []
    with gzip.open(csv_path, "rt", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split(",")
            if len(parts) >= 2:
                cnpj = parts[1].strip()
                if cnpj and len(cnpj) == 14:
                    out.append(cnpj)
                    if len(out) >= n:
                        break
    return out


def read_proc_rss_kb(pid: int) -> int:
    """Lê VmHWM (high-watermark RSS) de /proc/<pid>/status, em kB."""
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    return int(line.split()[1])
    except (FileNotFoundError, ValueError, PermissionError):
        pass
    return 0


def fmt_bytes(n: int) -> str:
    if n < 1024:
        return f"{n}B"
    if n < 1024 * 1024:
        return f"{n/1024:.1f}KB"
    if n < 1024 * 1024 * 1024:
        return f"{n/1024/1024:.1f}MB"
    return f"{n/1024/1024/1024:.2f}GB"


def p95(values: list[float]) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    idx = int(len(s) * 0.95)
    return s[min(idx, len(s) - 1)]


# ============================================================================
# EAVT bench
# ============================================================================


def start_eavt_server(db_path: str) -> tuple[subprocess.Popen, int]:
    db = Path(db_path)
    if db.exists():
        shutil.rmtree(db)
    db.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.Popen(
        [str(_release / "eavt-server"), "rpc", db_path, "--addr", SERVER_ADDR, "--writable"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    for line in proc.stdout:
        if "listening" in line:
            break
    return proc, proc.pid


def eavt_disk_bytes(client: EavtClient) -> int:
    """Soma blobs + journal via status RPC."""
    resp = client.stub.Status(pb.StatusRequest())
    return resp.disk_usage + resp.wal_size


def bench_eavt(n: int, cnpjs: list[str], db_root: Path) -> BenchResult:
    db_path = str(db_root / f"eavt_{n}")
    proc, server_pid = start_eavt_server(db_path)
    try:
        client = EavtClient(SERVER_ADDR)

        client.execute("ATTRIBUTE cnpj.cnpj12 STRING ONE UNIQUE")
        client.execute("ATTRIBUTE cnpj.rowid  LONG   ONE UNIQUE")

        stmt_id = client.prepare("UPSERT SET cnpj.cnpj12 = %1, cnpj.rowid = %2")

        t0 = time.perf_counter()
        for i, cnpj in enumerate(cnpjs):
            client.execute_prepared(stmt_id, cnpj, i)
        ingest_s = time.perf_counter() - t0

        client.flush()
        disk = eavt_disk_bytes(client)
        ram = read_proc_rss_kb(server_pid)

        # Preparar statements de lookup
        stmt_cnpj_to_rowid = client.prepare(
            "SELECT d1.cnpj.rowid WHERE d1.cnpj.cnpj12 = %1"
        )
        stmt_rowid_to_cnpj = client.prepare(
            "SELECT d1.cnpj.cnpj12 WHERE d1.cnpj.rowid = %1"
        )

        # Amostras aleatórias para lookup
        import random
        rng = random.Random(42)
        sample_idx = [rng.randrange(n) for _ in range(LOOKUP_SAMPLES)]

        # CNPJ -> rowid (via execute_prepared)
        times_cnpj: list[float] = []
        for i in sample_idx:
            cnpj = cnpjs[i]
            t1 = time.perf_counter()
            _ = client.execute_prepared(stmt_cnpj_to_rowid, cnpj, limit=1)
            times_cnpj.append((time.perf_counter() - t1) * 1_000_000)

        # rowid -> CNPJ
        times_rowid: list[float] = []
        for i in sample_idx:
            t1 = time.perf_counter()
            _ = client.execute_prepared(stmt_rowid_to_cnpj, i, limit=1)
            times_rowid.append((time.perf_counter() - t1) * 1_000_000)

        # Range: 10K CNPJs consecutivos (alfabético)
        start_cnpj = cnpjs[0]
        end_idx = min(RANGE_SIZE, n) - 1
        end_cnpj = cnpjs[end_idx]
        t1 = time.perf_counter()
        rows = list(client.sql(
            "SELECT d1.cnpj.cnpj12, d1.cnpj.rowid WHERE d1.cnpj.cnpj12 >= %1 AND d1.cnpj.cnpj12 <= %2",
            start_cnpj, end_cnpj, limit=RANGE_SIZE,
        ))
        range_ms = (time.perf_counter() - t1) * 1000

        client.unprepare(stmt_id)
        client.unprepare(stmt_cnpj_to_rowid)
        client.unprepare(stmt_rowid_to_cnpj)
        client.close()

        return BenchResult(
            backend="EAVT",
            n=n,
            ingest_s=ingest_s,
            throughput_ops_s=n / ingest_s if ingest_s > 0 else 0,
            disk_bytes=disk,
            ram_peak_kb=ram,
            cnpj_to_rowid_p95_us=p95(times_cnpj),
            rowid_to_cnpj_p95_us=p95(times_rowid),
            range_10k_ms=range_ms,
            extra={"rows_returned_range": len(rows)},
        )
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


# ============================================================================
# mmap bench (CnpjSequencialMemory)
# ============================================================================


def bench_mmap(n: int, cnpjs: list[str], db_root: Path) -> BenchResult:
    from lib.cnpj_sequencial_memory import CnpjSequencialMemory

    mmap_path = db_root / f"mmap_{n}.mmap"
    if mmap_path.exists():
        os.remove(mmap_path)
    db_root.mkdir(parents=True, exist_ok=True)

    memory = CnpjSequencialMemory(str(mmap_path), mode="w")

    t0 = time.perf_counter()
    batch: list[str] = []
    BATCH = 50_000
    for cnpj in cnpjs:
        batch.append(cnpj)
        if len(batch) >= BATCH:
            memory.add_cnpjs(batch, skip_duplicates=True)
            batch = []
    if batch:
        memory.add_cnpjs(batch, skip_duplicates=True)
    memory.flush()
    ingest_s = time.perf_counter() - t0

    disk = os.path.getsize(mmap_path)
    rss_before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    rss_after_hwm = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss

    # Reopen for lookups
    memory = CnpjSequencialMemory(str(mmap_path), mode="r")

    import random
    rng = random.Random(42)
    sample_idx = [rng.randrange(n) for _ in range(LOOKUP_SAMPLES)]

    times_cnpj: list[float] = []
    for i in sample_idx:
        cnpj = cnpjs[i]
        t1 = time.perf_counter()
        memory.get_seq(cnpj)
        times_cnpj.append((time.perf_counter() - t1) * 1_000_000)

    times_rowid: list[float] = []
    for i in sample_idx:
        t1 = time.perf_counter()
        memory.get_cnpj_by_seq(i)
        times_rowid.append((time.perf_counter() - t1) * 1_000_000)

    # Range 10K
    import itertools
    start_cnpj = cnpjs[0]
    end_idx = min(RANGE_SIZE, n) - 1
    end_cnpj = cnpjs[end_idx]
    t1 = time.perf_counter()
    rows = list(itertools.islice(
        memory.query_range(start_cnpj, end_cnpj), RANGE_SIZE
    ))
    range_ms = (time.perf_counter() - t1) * 1000

    # RAM pico: linux getrusage retorna em kB (igual ao /proc)
    ram_hwm = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss

    return BenchResult(
        backend="mmap",
        n=n,
        ingest_s=ingest_s,
        throughput_ops_s=n / ingest_s if ingest_s > 0 else 0,
        disk_bytes=disk,
        ram_peak_kb=ram_hwm,
        cnpj_to_rowid_p95_us=p95(times_cnpj),
        rowid_to_cnpj_p95_us=p95(times_rowid),
        range_10k_ms=range_ms,
        extra={"rows_returned_range": len(rows)},
    )


# ============================================================================
# Report
# ============================================================================


def print_table(results: list[BenchResult]) -> None:
    if not results:
        return
    headers = [
        "N", "backend", "ingest_s", "ops/s", "disk", "ram_kb",
        "cnpj->rowid p95", "rowid->cnpj p95", "range 10k",
    ]
    rows = []
    for r in results:
        rows.append([
            f"{r.n:,}", r.backend, f"{r.ingest_s:.2f}",
            f"{r.throughput_ops_s:,.0f}", fmt_bytes(r.disk_bytes),
            f"{r.ram_peak_kb:,}",
            f"{r.cnpj_to_rowid_p95_us:.1f}us",
            f"{r.rowid_to_cnpj_p95_us:.1f}us",
            f"{r.range_10k_ms:.1f}ms",
        ])
    widths = [max(len(str(h)), max(len(r[i]) for r in rows)) for i, h in enumerate(headers)]
    sep = "+".join("-" * (w + 2) for w in widths)
    print("+" + sep + "+")
    print("| " + " | ".join(h.ljust(w) for h, w in zip(headers, widths)) + " |")
    print("+" + sep + "+")
    for r in rows:
        print("| " + " | ".join(c.ljust(w) for c, w in zip(r, widths)) + " |")
    print("+" + sep + "+")


def write_markdown_report(results: list[BenchResult], path: Path) -> None:
    lines = ["# Benchmark: EAVT vs CnpjSequencialMemory\n"]
    lines.append(f"_Gerado: {time.strftime('%Y-%m-%d %H:%M:%S')}_\n")
    lines.append("## Resultados\n")
    lines.append("| N | backend | ingest (s) | ops/s | disk | ram (kB) | cnpj->rowid p95 (us) | rowid->cnpj p95 (us) | range 10k (ms) |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for r in results:
        lines.append(
            f"| {r.n:,} | {r.backend} | {r.ingest_s:.2f} | {r.throughput_ops_s:,.0f} "
            f"| {fmt_bytes(r.disk_bytes)} | {r.ram_peak_kb:,} "
            f"| {r.cnpj_to_rowid_p95_us:.1f} | {r.rowid_to_cnpj_p95_us:.1f} "
            f"| {r.range_10k_ms:.1f} |"
        )
    lines.append("\n## Notas\n")
    lines.append("- EAVT: schema `cnpj.cnpj12 STRING UNIQUE` + `cnpj.rowid LONG UNIQUE`")
    lines.append("- EAVT: ingest via `ExecutePrepared` RPC (gRPC PreparedStatement)")
    lines.append("- mmap: `CnpjSequencialMemory` com hash table + sorted index + seq_to_idx")
    lines.append("- Lookups medem p95 sobre 1000 amostras aleatórias")
    lines.append("- Range: 10K CNPJs consecutivos alfabeticamente")
    path.write_text("\n".join(lines))


# ============================================================================
# main
# ============================================================================


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--steps", type=int, nargs="+", default=[100_000, 1_000_000, 5_000_000])
    ap.add_argument("--csv", default=CSV_DEFAULT)
    ap.add_argument("--db-root", default=str(DB_ROOT))
    ap.add_argument("--no-eavt", action="store_true")
    ap.add_argument("--no-mmap", action="store_true")
    ap.add_argument("--report", default=str(_root / "tests" / "bench_cnpj_eavt_vs_mmap_results.md"))
    args = ap.parse_args()

    if not Path(args.csv).exists():
        print(f"ERRO: CSV não encontrado: {args.csv}", file=sys.stderr)
        return 1

    db_root = Path(args.db_root)
    db_root.mkdir(parents=True, exist_ok=True)

    max_n = max(args.steps)
    print(f"Carregando {max_n:,} CNPJs do CSV {args.csv}...")
    t0 = time.perf_counter()
    cnpjs = load_cnpj_source(max_n, args.csv)
    load_s = time.perf_counter() - t0
    print(f"  {len(cnpjs):,} CNPJs carregados em {load_s:.2f}s")
    if len(cnpjs) < max_n:
        print(f"AVISO: CSV tem menos CNPJs que o máximo solicitado ({max_n}). Ajustando steps.")
        args.steps = [s for s in args.steps if s <= len(cnpjs)]

    results: list[BenchResult] = []
    for n in args.steps:
        print(f"\n=== N={n:,} ===")
        if not args.no_eavt:
            try:
                r = bench_eavt(n, cnpjs[:n], db_root)
                results.append(r)
                r_dict = asdict(r)
                r_dict.pop("extra")
                print("EAVT:", r_dict)
            except Exception as e:
                print(f"EAVT falhou: {e}", file=sys.stderr)
                import traceback; traceback.print_exc()
        if not args.no_mmap:
            try:
                r = bench_mmap(n, cnpjs[:n], db_root)
                results.append(r)
                r_dict = asdict(r)
                r_dict.pop("extra")
                print("mmap:", r_dict)
            except Exception as e:
                print(f"mmap falhou: {e}", file=sys.stderr)
                import traceback; traceback.print_exc()
        print_table(results)
        write_markdown_report(results, Path(args.report))

    print("\n=== FINAL ===")
    print_table(results)
    write_markdown_report(results, Path(args.report))
    print(f"Relatório markdown: {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
