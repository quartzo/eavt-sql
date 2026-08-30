#!/usr/bin/env python3
"""bench_receita_sqlite.py — Receita Federal load + point-lookup benchmark (SQLite).

Relational counterpart of tests/bench_receita_hydrated.py: same open-data
files, same "goc dessincronizado" mode (no membership filter, each line anchors
its empresa via INSERT OR IGNORE stub), same partial subsets proportional to the
full base (estabs 1.3N · simples 1.1N · sócios 0.5N), and the same extrapolation
to the full load using docs/perf-receita-carga.md rates.

Measures write rates per stage (rows/s) and point-lookup / join latency for the
SQLite schema, for side-by-side comparison against the EAVT Nim reference.

Usage:
    uv run python tests/bench_receita_sqlite.py --label baseline
    uv run python tests/bench_receita_sqlite.py --sizes 5000 --ops 200

Results are appended as JSON to /tmp/opencode/receita_bench_sqlite/<label>.json
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import random
import statistics
import sys
import tempfile
import time
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_root / "py_eavt" / "examples"))

import load_receita_sqlite as L  # noqa: E402

DEFAULT_SIZES = [5_000, 10_000, 25_000, 50_000]
OUT_DIR = Path("/tmp/opencode/receita_bench_sqlite")

RATIO_ESTABS = 1.3
RATIO_SIMPLES = 1.1
RATIO_SOCIOS = 0.5

FULL_ROWS = {"empresas": 46_000_000, "estabs": 73_000_000,
             "simples": 50_000_000, "socios": 28_000_000}


def _temp_db(label: str, n: int) -> str:
    d = Path(tempfile.gettempdir()) / "receita_sqlite_bench"
    d.mkdir(parents=True, exist_ok=True)
    return str(d / f"{label}_{n}_{os.getpid()}.db")


# ── Timing helpers ─────────────────────────────────────────────────────────────

def stats(samples: list[float]) -> dict:
    s = sorted(samples)
    n = len(s)
    us = lambda v: round(v * 1e6, 1)
    return {
        "n": n,
        "mean_us": us(statistics.fmean(s)),
        "p50_us": us(s[n // 2]),
        "p95_us": us(s[min(int(n * 0.95), n - 1)]),
        "max_us": us(s[-1]),
        "ops_per_s": int(round(n / max(sum(s), 1e-9))),
    }


def timed_probe(name: str, run_one, ids: list, warmup: int) -> dict:
    for x in ids[:min(warmup, len(ids))]:
        run_one(x)
    samples = []
    for x in ids:
        t0 = time.perf_counter()
        run_one(x)
        samples.append(time.perf_counter() - t0)
    st = stats(samples)
    print(f"  {name:<20} n={st['n']:<5} mean={st['mean_us']:>9.1f}µs  "
          f"p50={st['p50_us']:>9.1f}µs  p95={st['p95_us']:>9.1f}µs  "
          f"{st['ops_per_s']:>8,}/s", flush=True)
    return st


def first_n_cnpjs(data_dir: Path, n: int) -> list[str]:
    out = []
    for row in L.rows_from_zip(L.find_zip(data_dir, "Empresas0")):
        if len(row) >= 6 and len(row[0]) == 8:
            out.append(row[0])
            if len(out) >= n:
                break
    return out


# ── Per-size pipeline ─────────────────────────────────────────────────────────

def run_size(n: int, args, results: dict) -> None:
    print(f"\n{'=' * 70}\n== SIZE {n:,} ==\n{'=' * 70}", flush=True)

    db_path = _temp_db(args.label, n)
    conn = L.open_db(db_path)
    stage_secs: dict[str, float] = {}
    stage_rows: dict[str, int] = {}

    t0 = time.perf_counter()
    L.create_schema(conn)
    stage_secs["declare"] = time.perf_counter() - t0

    t0 = time.perf_counter()
    L.load_lookups(conn, args.data_dir)
    stage_secs["lookups"] = time.perf_counter() - t0

    t0 = time.perf_counter()
    loaded = L.load_empresas(conn, args.data_dir, n)
    stage_secs["empresas"] = time.perf_counter() - t0
    stage_rows["empresas"] = loaded

    cnpjs = first_n_cnpjs(args.data_dir, n)

    estab_rows = int(n * RATIO_ESTABS)
    simples_rows = int(n * RATIO_SIMPLES)
    socios_rows = int(n * RATIO_SOCIOS)

    if not args.skip_simples:
        try:
            t0 = time.perf_counter()
            pr = L.merge_simples(conn, args.data_dir, simples_rows)
            stage_secs["simples"] = time.perf_counter() - t0
            stage_rows["simples"] = pr
        except FileNotFoundError as e:
            print(f"  simples skipped: {e}")

    if not args.skip_estabs:
        t0 = time.perf_counter()
        sr, _ = L.load_estabs(conn, args.data_dir, estab_rows)
        stage_secs["estabs"] = time.perf_counter() - t0
        stage_rows["estabs"] = sr

    if not args.skip_socios:
        t0 = time.perf_counter()
        jr = L.load_socios(conn, args.data_dir, socios_rows)
        stage_secs["socios"] = time.perf_counter() - t0
        stage_rows["socios"] = jr

    t0 = time.perf_counter()
    L.create_indexes(conn)
    stage_secs["indexes"] = time.perf_counter() - t0

    total_load = sum(stage_secs.values())
    stages = " ".join(f"{k} {v:.2f}s" for k, v in stage_secs.items())
    print(f"-- load complete: {loaded:,} empresas, {total_load:.2f}s ({stages})",
          flush=True)

    rates = {k: stage_rows[k] / stage_secs[k]
             for k in stage_rows if stage_secs.get(k)}
    if rates:
        print("-- write rates: " +
              "  ".join(f"{k} {v:,.0f} rows/s" for k, v in sorted(rates.items())),
              flush=True)

    # Sample: seed-fixed, same cnpjs across labels for identical methodology.
    rng = random.Random(42)
    k = min(args.ops, len(cnpjs))
    sample = rng.sample(cnpjs, k)
    print(f"-- sample {len(sample)}/{len(cnpjs)} cnpjs --", flush=True)

    probes: dict[str, dict] = {}

    probes["pk_lookup"] = timed_probe(
        "pk_lookup(cnpj)",
        lambda c: conn.execute(
            "SELECT razao_social FROM empresa WHERE cnpj_base = ?", (c,)).fetchone(),
        sample, args.warmup)
    probes["attrs_x3"] = timed_probe(
        "attrs_x3(cnpj)",
        lambda c: conn.execute(
            "SELECT razao_social, capital_social, porte FROM empresa"
            " WHERE cnpj_base = ?", (c,)).fetchone(),
        sample, args.warmup)
    probes["upsert"] = timed_probe(
        "upsert(capital)",
        lambda i_c: (conn.execute(
            "UPDATE empresa SET capital_social = ? WHERE cnpj_base = ?",
            (1000.0 + (i_c[0] % 1000), i_c[1])), conn.commit()),
        list(enumerate(sample)), args.warmup)
    probes["sql_point"] = timed_probe(
        "sql_point(cnpj)",
        lambda c: conn.execute(
            "SELECT capital_social FROM empresa WHERE cnpj_base = ?", (c,)).fetchone(),
        sample, args.warmup)
    probes["estab_join"] = timed_probe(
        "estab_join(cnpj)",
        lambda c: conn.execute(
            "SELECT cnpj_completo FROM estabelecimento WHERE cnpj_base = ?",
            (c,)).fetchone(),
        sample, args.warmup)
    probes["socio_join"] = timed_probe(
        "socio_join(cnpj)",
        lambda c: conn.execute(
            "SELECT nome FROM socio WHERE cnpj_base = ? LIMIT 1", (c,)).fetchone(),
        sample, args.warmup)
    probes["pais_join"] = timed_probe(
        "pais_join(cnpj)",
        lambda c: conn.execute(
            "SELECT p.nome FROM estabelecimento e"
            " LEFT JOIN pais p ON e.pais_id = p.id"
            " WHERE e.cnpj_base = ? LIMIT 1", (c,)).fetchone(),
        sample, args.warmup)

    conn.close()
    os.remove(db_path)
    if Path(db_path + "-wal").exists():
        os.remove(db_path + "-wal")
    if Path(db_path + "-shm").exists():
        os.remove(db_path + "-shm")

    entry = {
        "n_loaded": loaded,
        "sample_k": len(sample),
        "load_total_secs": round(total_load, 3),
        "load_stages_secs": {k2: round(v, 3) for k2, v in stage_secs.items()},
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
    print(f"\n=== EXTRAPOLAÇÃO CARGA COMPLETA "
          f"(taxas @ n={best['n']:,}) ===")
    total_fixed = sum(v for k, v in best["load_stages_secs"].items()
                      if k in ("declare", "lookups", "indexes"))
    est_secs: dict[str, float] = {}
    for stage, full_rows in FULL_ROWS.items():
        rate = best["write_rates"].get(stage)
        if not rate:
            continue
        est_secs[stage] = full_rows / rate
    for stage, secs in sorted(est_secs.items()):
        print(f"  {stage:<9} {FULL_ROWS[stage]:>12,} linhas / "
              f"{best['write_rates'][stage]:>10,.0f} rows/s "
              f"→ {secs/3600:5.2f} h")
    hours = (sum(est_secs.values()) + total_fixed) / 3600
    print(f"  TOTAL estimado ≈ {hours:.2f} h (+{total_fixed:.1f}s fixos)")


def dump_results(results: dict, label: str) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{label}.json"
    with open(path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"[results → {path}]", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--label", default="baseline")
    ap.add_argument("--sizes", default=",".join(map(str, DEFAULT_SIZES)))
    ap.add_argument("--ops", type=int, default=500)
    ap.add_argument("--warmup", type=int, default=50)
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
            "seed": 42,
            "data_dir": str(args.data_dir),
        },
        "runs": [],
    }

    sizes = [int(s) for s in args.sizes.split(",")]
    for n in sizes:
        run_size(n, args, results)

    print("\n=== SUMMARY ===")
    for run in results["runs"]:
        print(f"n={run['n']:>7,}  load={run['load_total_secs']:>8.3f}s  ", end="")
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
