#!/usr/bin/env python3
"""bench_save_many.py — flat (save ...) vs agrupado (save-many ...) no transactor.

Mesmas 20k entidades sintéticas × 4 attrs (cnpj_base unique/AVET, razao,
porte, capital float), eids sintéticos em ambos os lados (sem alloc) para
isolar o ganho do formato: N formas save por batch vs 1 forma save-many
por atributo por batch.

Usage:
    uv run python tests/bench_save_many.py [--rows 20000]
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_root / "py_eavt_client" / "src"))
sys.path.insert(0, str(_root / "py_eavt" / "examples"))

from eavt_client.client import EavtClient  # noqa: E402
import load_receita_sql as L  # noqa: E402


def sock_path() -> Path:
    import os
    base = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "eavt"
    return base / "eavt-query.sock"


def restart_stack() -> None:
    subprocess.run([str(_root / "scripts" / "stop.sh")], capture_output=True, check=True)
    subprocess.run([str(_root / "scripts" / "start.sh")], capture_output=True, check=True)


def connect(timeout: float = 20.0) -> EavtClient:
    sp = sock_path()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if sp.exists():
            try:
                return EavtClient(str(sp))
            except (ConnectionError, FileNotFoundError, OSError):
                pass
        time.sleep(0.2)
    raise RuntimeError(f"query server not reachable at {sp}")


def synth_rows(n: int, seed_offset: int = 0) -> list[tuple[int, str, str, str, float]]:
    """(eid, cnpj_base, razao, porte, capital) determinísticos."""
    out = []
    for i in range(n):
        eid = 1_000_000 + i + seed_offset
        cnpj = f"{20000000 + i + seed_offset:08d}"
        razao = f"EMPRESA TESTE {i:06d} LTDA"
        porte = "05" if i % 3 else "03"
        capital = 1000.0 + (i % 997) * 13.5
        out.append((eid, cnpj, razao, porte, capital))
    return out


ATTRS = ["empresa.cnpj_base", "empresa.razao_social",
         "empresa.porte", "empresa.capital_social"]


def flush_old(client: EavtClient, rows) -> None:
    """N×4 formas (save e attr val) num único begin."""
    body = []
    for (eid, cnpj, razao, porte, capital) in rows:
        e = L.WInt(eid)
        body.append(L.WForm(L.SAVE, e, L.WAttr("empresa.cnpj_base"), L.WStr(cnpj)))
        body.append(L.WForm(L.SAVE, e, L.WAttr("empresa.razao_social"), L.WStr(razao)))
        body.append(L.WForm(L.SAVE, e, L.WAttr("empresa.porte"), L.WStr(porte)))
        body.append(L.WForm(L.SAVE, e, L.WAttr("empresa.capital_social"),
                            L.WFloat(capital)))
    body.append(L.WForm(L.RESULT, L.WInt(0)))
    client.scheme_wire(L.WForm(L.BEGIN, *body), mode="exec")


def flush_new(client: EavtClient, rows) -> None:
    """4 formas (save-many attr e v e v ...), uma por atributo."""
    by_attr: dict[str, list] = {a: [] for a in ATTRS}
    for (eid, cnpj, razao, porte, capital) in rows:
        by_attr["empresa.cnpj_base"].extend([L.WInt(eid), L.WStr(cnpj)])
        by_attr["empresa.razao_social"].extend([L.WInt(eid), L.WStr(razao)])
        by_attr["empresa.porte"].extend([L.WInt(eid), L.WStr(porte)])
        by_attr["empresa.capital_social"].extend([L.WInt(eid), L.WFloat(capital)])
    body = []
    for attr in ATTRS:
        nodes = by_attr[attr]
        if nodes:
            body.append(L.WForm(L.WSym("save-many"), L.WAttr(attr), *nodes))
    body.append(L.WForm(L.RESULT, L.WInt(0)))
    client.scheme_wire(L.WForm(L.BEGIN, *body), mode="exec")


def run_variant(name: str, flush, rows, batch: int) -> float:
    restart_stack()
    client = connect()
    t0 = time.perf_counter()
    L.declare_schema(client)
    t_decl = time.perf_counter() - t0
    t0 = time.perf_counter()
    for i in range(0, len(rows), batch):
        flush(client, rows[i:i + batch])
    dt = time.perf_counter() - t0
    # sanity: valor pousou no lugar certo (param é var-posicional: string
    # direta, sem lista; ver client.execute/​sql)
    probe = rows[len(rows) // 2][1]
    try:
        got = client.execute(
            "SELECT d1.empresa.capital_social WHERE d1.empresa.cnpj_base = %1", probe)
        ok = bool(got) and abs(float(got[0][0]) - rows[len(rows) // 2][4]) < 1e-6
    except RuntimeError as e:
        ok = False
        print(f"  [{name}] SQL FALHOU: {e}", flush=True)
    if not ok:
        # Armadilha de diagnóstico: captura o estado do snapshot na falha
        sch = client.schema()
        ids = sch.get("attrIds", {})
        print(f"  [{name}] SNAPSHOT attrs={len(ids)} "
              f"cnpj_base={ids.get('empresa.cnpj_base')} "
              f"capital={ids.get('empresa.capital_social')}", flush=True)
        raise SystemExit(2)
    print(f"  {name:<10} declare={t_decl:5.1f}s  load={dt:6.2f}s  "
          f"({len(rows) / dt:,.0f} empresas/s, {len(rows) * 4 / dt:,.0f} saves/s)",
          flush=True)
    client.close()
    return dt


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rows", type=int, default=20000)
    ap.add_argument("--batch", type=int, default=500)
    args = ap.parse_args()

    rows = synth_rows(args.rows)

    print(f"== save flat vs save-many: {args.rows:,} entidades × 4 attrs ==")
    t_old = run_variant("flat", flush_old, rows, args.batch)
    t_new = run_variant("save-many", flush_new, rows, args.batch)

    print(f"\n=== SUMMARY ===")
    print(f"flat      : {t_old:6.2f}s")
    print(f"save-many : {t_new:6.2f}s  ({t_old / t_new:.2f}x)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
