#!/usr/bin/env python3
"""bench_receita_hydrated.py — Receita Federal load + point-lookup benchmark.

Measures the paths targeted by the hydrated-eid cache (docs/perf-hydrated-eids.md):

  eid_lookup     AVET point lookup  (control — should not change post-hydration)
  attr_by_eid    EAVT point lookup  (target — lookupValue fast path)
  attrs_x3       three attrs, one round trip (amortized hydrated entry)
  upsert         save over existing card-ONE attr (retract-scan fast path)
  sql_point      end-to-end SQL reference (planner + scanner)

Orchestration per size: scripts/stop.sh + scripts/start.sh (fresh DB),
full partial Receita load, then timed probes on a seed-fixed sample.

Usage:
    uv run python tests/bench_receita_hydrated.py --label baseline
    uv run python tests/bench_receita_hydrated.py --sizes 5000 --ops 200

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

from eavt_client.client import EavtClient  # noqa: E402
import load_receita_sql as L  # noqa: E402

DEFAULT_SIZES = [5_000, 10_000, 25_000, 50_000]
OUT_DIR = Path("/tmp/opencode/receita_bench")

RR = L.WSym("result-row")
LOOKUP_ENTITY = L.WSym("lookup-entity")
LOOKUP_VALUE = L.WSym("lookup-value")
EID_VAR = L.WSym("e")


# ── Stack orchestration ───────────────────────────────────────────────────────

def sock_path(name: str) -> Path:
    import os
    base = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "eavt"
    return base / name


def restart_stack() -> None:
    """stop.sh + start.sh → guaranteed-fresh DB (start.sh wipes by default)."""
    subprocess.run([str(_root / "scripts" / "stop.sh")],
                   capture_output=True, check=True)
    subprocess.run([str(_root / "scripts" / "start.sh")],
                   capture_output=True, check=True)


def connect(timeout: float = 20.0) -> EavtClient:
    """Poll for the query socket, then connect with retries."""
    sp = sock_path("eavt-query.sock")
    deadline = time.monotonic() + timeout
    last_err = None
    while time.monotonic() < deadline:
        if sp.exists():
            try:
                return EavtClient(str(sp))
            except (ConnectionError, FileNotFoundError, OSError) as e:
                last_err = e
        time.sleep(0.2)
    raise RuntimeError(f"query server not reachable at {sp}: {last_err}")


# ── Filtered bulk loads (membership-checked against loaded empresas) ─────────

def merge_simples_filtered(client: EavtClient, data_dir: Path,
                           members: set[str], batch_size: int) -> tuple[int, int]:
    """merge_simples restricted to loaded cnpj_bases.

    The example loader's merge_simples gocs EVERY matching row of the
    country-wide Simples file (~50M rows) — not partial data. Here we keep
    only rows whose base is among the loaded empresas.
    """
    zpath = data_dir / "Simples__20260809T1834.zip"
    matched = scanned = 0
    batch_body: list[list] = []
    t0 = time.perf_counter()

    def flush():
        nonlocal batch_body, matched
        if not batch_body:
            return
        batch_body.append(L.WForm(L.RESULT, L.E_SYM, L.WInt(len(batch_body))))
        client.scheme_wire(L.WForm(L.BEGIN, *batch_body), mode="exec")
        matched += 1
        batch_body = []

    for row in L.rows_from_zip(zpath):
        scanned += 1
        if scanned % 5_000_000 == 0:
            print(f"    simples: scanned {scanned:,}, matched {matched:,} "
                  f"({time.perf_counter() - t0:.1f}s)", flush=True)
        if len(row) < 7 or row[0] not in members:
            continue

        sets = []
        if row[1]:
            sets.append(("empresa.optante_simples", row[1]))
        if row[2] and row[2] != L.ZERO_DATE:
            sets.append(("empresa.data_opcao_simples", row[2]))
        if row[3] and row[3] != L.ZERO_DATE:
            sets.append(("empresa.data_exclusao_simples", row[3]))
        if row[4]:
            sets.append(("empresa.optante_mei", row[4]))
        if row[5] and row[5] != L.ZERO_DATE:
            sets.append(("empresa.data_opcao_mei", row[5]))
        if row[6] and row[6] != L.ZERO_DATE:
            sets.append(("empresa.data_exclusao_mei", row[6]))
        if not sets:
            continue

        batch_body.append(L.WForm(L.SETBANG, L.E_SYM,
                                  L.goc("empresa.cnpj_base", row[0])))
        for attr, val in sets:
            batch_body.append(L.WForm(L.WHEN, L.E_SYM,
                                      L.WForm(L.SAVE, L.E_SYM,
                                              L.WAttr(attr), L.WStr(val))))
        if len(batch_body) >= batch_size * 2:
            flush()

    flush()
    print(f"  simples(filtered): {matched:,} empresas touched "
          f"(scanned {scanned:,}) in {time.perf_counter() - t0:.1f}s", flush=True)
    return matched, scanned


def load_estabs_filtered(client: EavtClient, data_dir: Path,
                         members: set[str], batch_size: int) -> tuple[int, int]:
    zpath = L.find_zip(data_dir, "Estabelecimentos0")
    batch: list[list[str]] = []
    saved = scanned = 0
    t0 = time.perf_counter()
    for row in L.rows_from_zip(zpath):
        scanned += 1
        if scanned % 1_000_000 == 0:
            print(f"    estabs: scanned {scanned:,}, saved {saved:,} "
                  f"({time.perf_counter() - t0:.1f}s)", flush=True)
        if len(row) < 30 or len(row[0]) != 8 or not row[0].isdigit():
            continue
        if row[0] not in members:
            continue
        batch.append(row)
        if len(batch) >= batch_size:
            L._flush_estab_batch(client, batch)
            saved += len(batch)
            batch = []
    if batch:
        L._flush_estab_batch(client, batch)
        saved += len(batch)
    print(f"  estabs(filtered): {saved:,} (scanned {scanned:,}) in "
          f"{time.perf_counter() - t0:.1f}s", flush=True)
    return saved, scanned


def load_socios_filtered(client: EavtClient, data_dir: Path,
                         members: set[str], batch_size: int) -> tuple[int, int]:
    zpath = L.find_zip(data_dir, "Socios0")
    batch: list[list[str]] = []
    saved = scanned = 0
    t0 = time.perf_counter()
    for row in L.rows_from_zip(zpath):
        scanned += 1
        if scanned % 1_000_000 == 0:
            print(f"    socios: scanned {scanned:,}, saved {saved:,} "
                  f"({time.perf_counter() - t0:.1f}s)", flush=True)
        if len(row) < 11 or len(row[0]) != 8 or not row[0].isdigit():
            continue
        if row[0] not in members:
            continue
        batch.append(row)
        if len(batch) >= batch_size:
            L._flush_socio_batch(client, batch)
            saved += len(batch)
            batch = []
    if batch:
        L._flush_socio_batch(client, batch)
        saved += len(batch)
    print(f"  socios(filtered): {saved:,} (scanned {scanned:,}) in "
          f"{time.perf_counter() - t0:.1f}s", flush=True)
    return saved, scanned


# ── Probe programs (wire-tagged scheme) ───────────────────────────────────────

def prog_eid_lookup(cnpj: str) -> list:
    return L.WForm(RR, L.WForm(LOOKUP_ENTITY, L.WAttr("empresa.cnpj_base"),
                               L.WStr(cnpj)))


def prog_attr_by_eid(eid: int, attr: str) -> list:
    return L.WForm(RR, L.WForm(LOOKUP_VALUE, L.WInt(eid), L.WAttr(attr)))


def prog_attrs_x3(eid: int) -> list:
    return L.WForm(L.BEGIN,
                   L.WForm(RR, L.WForm(LOOKUP_VALUE, L.WInt(eid),
                                       L.WAttr("empresa.razao_social"))),
                   L.WForm(RR, L.WForm(LOOKUP_VALUE, L.WInt(eid),
                                       L.WAttr("empresa.capital_social"))),
                   L.WForm(RR, L.WForm(LOOKUP_VALUE, L.WInt(eid),
                                       L.WAttr("empresa.porte"))))


def prog_upsert(cnpj: str, capital: float) -> list:
    # exec mode requires the program's final value to be a (result ...) form
    return L.WForm(
        L.BEGIN,
        L.WForm(L.SETBANG, EID_VAR,
                L.WForm(LOOKUP_ENTITY, L.WAttr("empresa.cnpj_base"),
                        L.WStr(cnpj))),
        L.WForm(L.WHEN, EID_VAR,
                L.WForm(L.SAVE, EID_VAR, L.WAttr("empresa.capital_social"),
                        L.WFloat(capital))),
        L.WForm(L.RESULT, EID_VAR, L.WInt(1)))


# ── Timing helpers ────────────────────────────────────────────────────────────

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
    print(f"  {name:<16} n={st['n']:<5} mean={st['mean_us']:>9.1f}µs  "
          f"p50={st['p50_us']:>9.1f}µs  p95={st['p95_us']:>9.1f}µs  "
          f"{st['ops_per_s']:>8,}/s", flush=True)
    return st


# ── Per-size pipeline ─────────────────────────────────────────────────────────

def first_n_cnpjs(data_dir: Path, n: int) -> list[str]:
    out = []
    for row in L.rows_from_zip(L.find_zip(data_dir, "Empresas0")):
        if len(row) >= 6 and len(row[0]) == 8 and row[0].isdigit():
            out.append(row[0])
            if len(out) >= n:
                break
    return out


def run_size(client_holder: list, n: int, args, results: dict) -> None:
    print(f"\n{'=' * 70}\n== SIZE {n:,} ==\n{'=' * 70}", flush=True)

    print("-- restarting stack (fresh DB) --", flush=True)
    restart_stack()
    client_holder[0] = connect()
    client = client_holder[0]

    stage_secs: dict[str, float] = {}
    t0 = time.perf_counter()
    L.declare_schema(client)
    stage_secs["declare"] = time.perf_counter() - t0

    t0 = time.perf_counter()
    L.load_lookups(client, args.data_dir, args.batch)
    stage_secs["lookups"] = time.perf_counter() - t0

    t0 = time.perf_counter()
    loaded = L.load_empresas(client, args.data_dir, n, args.batch)
    stage_secs["empresas"] = time.perf_counter() - t0

    cnpjs = first_n_cnpjs(args.data_dir, n)
    members = set(cnpjs)

    if not args.skip_simples:
        try:
            t0 = time.perf_counter()
            merge_simples_filtered(client, args.data_dir, members, args.batch)
            stage_secs["simples"] = time.perf_counter() - t0
        except FileNotFoundError as e:
            print(f"  simples skipped: {e}")

    if not args.skip_estabs:
        t0 = time.perf_counter()
        load_estabs_filtered(client, args.data_dir, members, args.batch)
        stage_secs["estabs"] = time.perf_counter() - t0

    if not args.skip_socios:
        t0 = time.perf_counter()
        load_socios_filtered(client, args.data_dir, members, args.batch)
        stage_secs["socios"] = time.perf_counter() - t0

    total_load = sum(stage_secs.values())
    stages = " ".join(f"{k} {v:.1f}s" for k, v in stage_secs.items())
    print(f"-- load complete: {loaded:,} empresas, {total_load:.1f}s ({stages})",
          flush=True)

    # Sample: seed-fixed, same cnpjs across labels for identical methodology
    rng = random.Random(42)
    k = min(args.ops, len(cnpjs))
    sample_cnpjs = rng.sample(cnpjs, k)

    # Pre-resolve eids outside timing (AVET, untimed).
    # NOTE: programs are already wire-tagged (WForm/WInt/...) → scheme_wire,
    # NOT scheme() (which would re-encode tags as data children).
    eids = []
    for c in sample_cnpjs:
        chunks = client.scheme_wire(prog_eid_lookup(c), mode="query")
        rows = chunks[0].get("rows", [])
        eids.append(rows[0][0] if rows else None)
    paired = [(c, e) for c, e in zip(sample_cnpjs, eids) if e is not None]
    print(f"-- resolved {len(paired)}/{k} sample eids --", flush=True)
    sc = [c for c, _ in paired]
    se = [e for _, e in paired]

    probes: dict[str, dict] = {}

    def q(program):
        client.scheme_wire(program, mode="query")

    def x(program):
        client.scheme_wire(program, mode="exec")

    print("-- probes --", flush=True)
    probes["eid_lookup"] = timed_probe(
        "eid_lookup(AVET)", lambda c: q(prog_eid_lookup(c)), sc, args.warmup)
    probes["attr_by_eid"] = timed_probe(
        "attr_by_eid(EAVT)",
        lambda e: q(prog_attr_by_eid(e, "empresa.razao_social")), se, args.warmup)
    probes["attrs_x3"] = timed_probe(
        "attrs_x3", lambda e: q(prog_attrs_x3(e)), se, args.warmup)
    probes["upsert"] = timed_probe(
        "upsert(capital)",
        lambda i_c: x(prog_upsert(i_c[1],
                                  1000.0 + (i_c[0] % 1000))), 
        list(enumerate(sc)), args.warmup)
    probes["sql_point"] = timed_probe(
        "sql_point(SQL)",
        lambda c: client.execute(
            "SELECT d1.empresa.capital_social WHERE d1.empresa.cnpj_base = %1",
            c), sc, args.warmup)

    entry = {
        "n_loaded": loaded,
        "sample_k": len(paired),
        "load_total_secs": round(total_load, 1),
        "load_stages_secs": {k2: round(v, 1) for k2, v in stage_secs.items()},
        "probes": probes,
    }
    results["runs"].append({"n": n, **entry})
    dump_results(results, args.label)
    print(f"-- checkpoint recorded (n={n}) --", flush=True)


def dump_results(results: dict, label: str) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{label}.json"
    with open(path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"[results → {path}]", flush=True)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--label", default="baseline",
                    help="run label (baseline | hydrated)")
    ap.add_argument("--sizes", default=",".join(map(str, DEFAULT_SIZES)))
    ap.add_argument("--ops", type=int, default=500,
                    help="timed operations per probe (default 500)")
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
