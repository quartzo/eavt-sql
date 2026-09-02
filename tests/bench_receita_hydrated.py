#!/usr/bin/env python3
"""bench_receita_hydrated.py — Receita Federal load + point-lookup benchmark (EDN).

Everything goes through the tx protocol (docs/tx-protocol.md) and Datalog EDN:
- Schema: tx schema-as-data
- Carga: tx :db/add with tempid upsert on :db.unique/identity attrs
- Probes: Datalog EDN queries + tx writes

Results are appended as JSON to /tmp/opencode/receita_bench/<label>.json
"""
from __future__ import annotations

import argparse
import json
import platform
import random
import statistics
import subprocess
import sys
import time
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_root / "py_eavt_client" / "src"))
sys.path.insert(0, str(_root / "py_eavt" / "examples"))

from eavt_client.client import EavtClient, Kw  # noqa: E402
import load_receita_edn as L
from load_receita_edn import timed_probe, stats  # noqa: E402

DEFAULT_SIZES = [5_000, 10_000, 25_000, 50_000]
OUT_DIR = Path("/tmp/opencode/receita_bench")

# razões aproximadas da base completa vs empresas
RATIO_ESTABS = 1.3
RATIO_SIMPLES = 1.1
RATIO_SOCIOS = 0.5

FULL_ROWS = {"empresas": 46_000_000, "estabs": 73_000_000,
             "simples": 50_000_000, "socios": 28_000_000}


def sock_path(name: str) -> Path:
    import os
    base = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "eavt"
    return base / name


def restart_stack() -> None:
    subprocess.run([str(_root / "scripts" / "stop.sh")], capture_output=True, check=True)
    subprocess.run([str(_root / "scripts" / "start.sh")], capture_output=True, check=True)


def connect(timeout: float = 20.0) -> EavtClient:
    sp = sock_path("eavt-query.sock")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if sp.exists():
            try:
                return EavtClient(str(sp))
            except (ConnectionError, FileNotFoundError, OSError):
                pass
        time.sleep(0.2)
    raise RuntimeError(f"query server not reachable at {sp}")

# ── Carga goc → tx upsert ────────────────────────────────────────────────────

SIMPLES_ZIP = "Simples__20260809T1834.zip"


def merge_simples_goc(client, data_dir: Path,
                      max_rows: int, batch_size: int) -> tuple[int, int]:
    """Simples merge via tx upsert on cnpj_base unique anchor."""
    zpath = data_dir / SIMPLES_ZIP
    processed = scanned = 0
    ops: list[list] = []
    t0 = time.perf_counter()

    for row in L.rows_from_zip(zpath):
        scanned += 1
        if len(row) < 7: continue
        sets = []
        if row[1]: sets.append(("empresa/optante_simples", row[1]))
        if row[2] and row[2] != L.ZERO_DATE: sets.append(("empresa/data_opcao_simples", row[2]))
        if row[3] and row[3] != L.ZERO_DATE: sets.append(("empresa/data_exclusao_simples", row[3]))
        if row[4]: sets.append(("empresa/optante_mei", row[4]))
        if row[5] and row[5] != L.ZERO_DATE: sets.append(("empresa/data_opcao_mei", row[5]))
        if row[6] and row[6] != L.ZERO_DATE: sets.append(("empresa/data_exclusao_mei", row[6]))
        if not sets: continue

        # upsert by cnpj_base unique anchor
        ops.append(L.op_add(-1, "empresa/cnpj_base", row[0]))
        for attr, val in sets:
            ops.append(L.op_add(-1, attr, val))
        if len(ops) >= batch_size * 2:
            L.tx_batch(client, ops)
            processed += 1
            ops = []
        if processed >= max_rows:
            break
    if ops:
        L.tx_batch(client, ops)
        processed += 1
    print(f"  simples(tx): {processed:,} linhas gravadas "
          f"(scanned {scanned:,}) in {time.perf_counter() - t0:.1f}s", flush=True)
    return processed, scanned


def load_estabs_tx(client, data_dir: Path,
                   max_rows: int, batch_size: int) -> tuple[int, int]:
    """Estabs via tx :db/add with tempid upsert on cnpj_completo."""
    zpath = L.find_zip(data_dir, "Estabelecimentos0")
    batch: list = []
    saved = scanned = 0
    t0 = time.perf_counter()
    for row in L.rows_from_zip(zpath):
        scanned += 1
        if len(row) < 30 or len(row[0]) != 8 or not row[0].isdigit():
            continue
        batch.append(row)
        if len(batch) >= batch_size:
            L._flush_estab_batch(client, batch)
            saved += len(batch)
            batch = []
            if saved >= max_rows: break
    if batch and saved < max_rows:
        L._flush_estab_batch(client, batch)
        saved += len(batch)
    print(f"  estabs(tx): {saved:,} linhas gravadas "
          f"(scanned {scanned:,}) in {time.perf_counter() - t0:.1f}s", flush=True)
    return saved, scanned


def load_socios_tx(client, data_dir: Path,
                   max_rows: int, batch_size: int) -> tuple[int, int]:
    zpath = L.find_zip(data_dir, "Socios0")
    batch: list = []
    saved = scanned = 0
    t0 = time.perf_counter()
    for row in L.rows_from_zip(zpath):
        scanned += 1
        if len(row) < 11 or len(row[0]) != 8 or not row[0].isdigit(): continue
        batch.append(row)
        if len(batch) >= batch_size:
            L._flush_socio_batch(client, batch)
            saved += len(batch)
            batch = []
            if saved >= max_rows: break
    if batch and saved < max_rows:
        L._flush_socio_batch(client, batch)
        saved += len(batch)
    print(f"  socios(tx): {saved:,} linhas gravadas "
          f"(scanned {scanned:,}) in {time.perf_counter() - t0:.1f}s", flush=True)
    return saved, scanned

# ── Probes (Datalog EDN + tx writes) ─────────────────────────────────────────

def prog_eid_lookup(cnpj: str) -> str:
    """Datalog query: eid of a empresa by cnpj_base unique value."""
    return "[:find ?e :where [?e :empresa.cnpj_base ?cnpj]]"


def run_size(client_holder: list, n: int, args, results: dict) -> None:
    print(f"\n{'=' * 70}\n== SIZE {n:,} ==\n"
          f"== modo: tx + Datalog EDN ==\n"
          f"{'=' * 70}", flush=True)

    print("-- restarting stack (fresh DB) --", flush=True)
    restart_stack()
    client_holder[0] = connect()
    client = client_holder[0]

    stage_secs: dict[str, float] = {}
    stage_rows: dict[str, int] = {}

    t0 = time.perf_counter()
    L.declare_schema(client)
    stage_secs["declare"] = time.perf_counter() - t0

    t0 = time.perf_counter()
    L.load_lookups(client, args.data_dir, args.batch)
    stage_secs["lookups"] = time.perf_counter() - t0

    t0 = time.perf_counter()
    loaded = L.load_empresas(client, args.data_dir, n, args.batch)
    stage_secs["empresas"] = time.perf_counter() - t0
    stage_rows["empresas"] = loaded

    cnpjs = L.first_n_cnpjs(args.data_dir, n) if hasattr(L, 'first_n_cnpjs') else []

    # subsets proporcionais
    estab_rows = int(n * RATIO_ESTABS)
    simples_rows = int(n * RATIO_SIMPLES)
    socios_rows = int(n * RATIO_SOCIOS)

    if not args.skip_simples:
        try:
            t0 = time.perf_counter()
            pr, _ = L.merge_simples(client, args.data_dir, args.batch)
            stage_secs["simples"] = time.perf_counter() - t0
            stage_rows["simples"] = pr
        except FileNotFoundError:
            print("  simples skipped")

    if not args.skip_estabs:
        t0 = time.perf_counter()
        sr, _ = L.load_estabs_bulk(client, args.data_dir, estab_rows, args.batch)
        stage_secs["estabs"] = time.perf_counter() - t0
        stage_rows["estabs"] = sr

    if not args.skip_socios:
        t0 = time.perf_counter()
        jr, _ = L.load_socios(client, args.data_dir, args.batch, socios_rows)
        stage_secs["socios"] = time.perf_counter() - t0
        stage_rows["socios"] = jr

    total_load = sum(stage_secs.values())
    stages = " ".join(f"{k} {v:.1f}s" for k, v in stage_secs.items())
    print(f"-- load complete: {loaded:,} empresas, {total_load:.1f}s ({stages})",
          flush=True)

    rates = {k: stage_rows[k] / stage_secs[k]
             for k in stage_rows if stage_secs.get(k)}
    if rates:
        print("-- write rates: " +
              "  ".join(f"{k} {v:,.0f} rows/s" for k, v in sorted(rates.items())),
              flush=True)

    # ── Probes (Datalog queries + tx writes) ──
    rng = random.Random(42)
    k = min(args.ops, len(cnpjs))
    sample_cnpjs = rng.sample(cnpjs, k) if cnpjs else []

    # Pre-resolve eids via Datalog (untimed)
    eids = []
    for c in sample_cnpjs:
        rows = client.q("[:find ?e :where [?e :empresa.cnpj_base ?cnpj]]", c)
        eids.append(rows[0][0] if rows else None)
    paired = [(c, e) for c, e in zip(sample_cnpjs, eids) if e is not None]
    print(f"-- resolved {len(paired)}/{k} sample eids --", flush=True)
    sc = [c for c, _ in paired]
    se = [e for _, e in paired]

    probes: dict[str, dict] = {}

    print("-- probes --", flush=True)

    # eid_lookup: Datalog projection
    def q_eid(cnpj):
        client.q("[:find ?e :where [?e :empresa.cnpj_base ?cnpj]]", cnpj)
    probes["eid_lookup"] = timed_probe(
        "eid_lookup(q)", lambda c: q_eid(c), sc, args.warmup)

    # attr_by_eid: Datalog with eid param
    def q_attr(eid):
        client.q("[:find ?v :in $ ?e :where [?e :empresa.razao_social ?v]]", eid)
    probes["attr_by_eid"] = timed_probe(
        "attr_by_eid(q)", lambda e: client.q(
            "[:find ?v :in $ ?e :where [?e :empresa.razao_social ?v]]", e),
        se, args.warmup)

    # attrs_x3: three attrs, one Datalog query
    probes["attrs_x3"] = timed_probe(
        "attrs_x3(q)", lambda e: client.q(
            "[:find ?rs ?cs ?p :in $ ?e :where [?e :empresa.razao_social ?rs] "
            "[?e :empresa.capital_social ?cs] [?e :empresa.porte ?p]]", e),
        se, args.warmup)

    # upsert: tx :db/add on resolved eid
    def upsert_probe(e):
        client.tx([[Kw("db/add"), e, Kw("empresa.capital_social"),
                    1000.0]])
    probes["upsert"] = timed_probe(
        "upsert(tx)", lambda e: upsert_probe(e), se, args.warmup)

    entry = {
        "n_loaded": loaded,
        "sample_k": len(paired),
        "load_total_secs": round(sum(stage_secs.values()), 1),
        "load_stages_secs": {k2: round(v, 1) for k2, v in stage_secs.items()},
        "write_rates": {k2: round(v) for k2, v in rates.items()},
        "probes": probes,
    }
    results["runs"].append({"n": n, **entry})
    dump_results(results, args.label)
    print(f"-- checkpoint recorded (n={n}) --", flush=True)


def extrapolate(results: dict) -> None:
    runs = [r for r in results["runs"] if r.get("write_rates")]
    if not runs:
        return
    best = max(runs, key=lambda r: r["n"])
    print(f"\n=== EXTRAPOLAÇÃO CARGA COMPLETA (taxas @ n={best['n']:,}) ===")
    total_fixed = sum(v for k, v in best["load_stages_secs"].items() if k in ("declare", "lookups"))
    est_secs: dict[str, float] = {}
    for stage, full_rows in FULL_ROWS.items():
        rate = best["write_rates"].get(stage)
        if not rate:
            continue
        est_secs[stage] = full_rows / rate
    for stage, secs in sorted(est_secs.items()):
        print(f"  {stage:<9} {FULL_ROWS[stage]:>12,} linhas / "
              f"{best['write_rates'][stage]:>10,.0f} rows/s → {secs/3600:5.2f} h")
    hours = (sum(est_secs.values()) + total_fixed) / 3600
    print(f"  TOTAL estimado ≈ {hours:.1f} h (+{total_fixed:.0f}s fixos)")


def dump_results(results: dict, label: str) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{label}.json"
    with open(path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"[results → {path}]", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--label", default="edn")
    ap.add_argument("--sizes", default=",".join(map(str, DEFAULT_SIZES)))
    ap.add_argument("--ops", type=int, default=500)
    ap.add_argument("--warmup", type=int, default=50)
    ap.add_argument("--batch", type=int, default=L.BATCH_SIZE)
    ap.add_argument("--data-dir", type=Path, default=L.DEFAULT_DATA)
    ap.add_argument("--skip-simples", action="store_true")
    ap.add_argument("--skip-estabs", action="store_true")
    ap.add_argument("--skip-socios", action="store_true")
    args = ap.parse_args()

    results = {
        "meta": {
            "label": args.label,
            "date": time.strftime("%Y-%m-%d %H:%M:%S"),
            "host": platform.node(),
            "python": platform.python_version(),
            "ops_per_probe": args.ops,
            "warmup": args.warmup,
            "batch": args.batch,
            "skips": [k for k, v in (("simples", args.skip_simples),
                                     ("estabs", args.skip_estabs),
                                     ("socios", args.skip_socios)) if v],
            "seed": 42,
            "data_dir": str(args.data_dir),
        },
        "runs": [],
    }

    sizes = [int(s) for s in args.sizes.split(",")]
    holder = [None]
    try:
        for n in sizes:
            run_size(holder, n, args, results)
    finally:
        if holder[0] is not None:
            try:
                holder[0].close()
            except Exception:
                pass

    print("\n=== SUMMARY ===")
    for run in results["runs"]:
        print(f"n={run['n']:>7,}  load={run['load_total_secs']:>7.1f}s  ", end="")
        for name, st in run["probes"].items():
            print(f"{name}: p50={st['p50_us']}µs  ", end="")
        print()
        if run.get("write_rates"):
            print("   rates: " + "  ".join(
                f"{k}={v:,.0f}/s" for k, v in sorted(run["write_rates"].items())))
    extrapolate(results)
    return 0


if __name__ == "__main__":
    sys.exit(main())
