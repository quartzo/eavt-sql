#!/usr/bin/env python3
"""load_receita_sql.py — Load Receita Federal CNPJ data via the Nim query server.

Same data as load_receita.py but routes everything through the UDS query server
using SQL (ATTRIBUTE) and Scheme batched programs for bulk loading.

Usage:
    uv run python py_eavt/examples/load_receita_sql.py --n 5000    # quick test
    uv run python py_eavt/examples/load_receita_sql.py              # full 1M empresas

Source: /home/fabio/dev/dagster_flows/tests_data/receita_zip
        (latin-1, ';'-separated, all fields quoted, no header)
"""
from __future__ import annotations

import argparse
import csv
import io
import sys
import time
import zipfile
from pathlib import Path

_root = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_root / "py_eavt_client" / "src"))

from eavt_client.client import EavtClient, Sym  # noqa: E402

DEFAULT_DATA = Path("/home/fabio/dev/dagster_flows/tests_data/receita_zip")
BATCH_SIZE = 500
ZERO_DATE = "00000000"


def rows_from_zip(zip_path: Path):
    with zipfile.ZipFile(zip_path) as zf:
        name = zf.namelist()[0]
        with zf.open(name) as f:
            text = io.TextIOWrapper(f, encoding="latin-1", newline="")
            yield from csv.reader(text, delimiter=";")


def find_zip(data_dir: Path, prefix: str) -> Path:
    matches = sorted(data_dir.glob(f"{prefix}__*.zip"))
    if not matches:
        raise FileNotFoundError(f"no zip matching {prefix}__* in {data_dir}")
    return matches[0]


# ═══════════════════════════════════════════════════════════════════════════════
# Schema
# ═══════════════════════════════════════════════════════════════════════════════

LOOKUPS = [
    ("Cnaes", "cnae", "descricao"),
    ("Municipios", "municipio", "nome"),
    ("Naturezas", "natureza", "descricao"),
    ("Qualificacoes", "qualificacao", "descricao"),
    ("Paises", "pais", "nome"),
    ("Motivos", "motivo", "descricao"),
]


def declare_schema(client: EavtClient):
    stmts = []
    for _, prefix, desc_attr in LOOKUPS:
        stmts.append(f"ATTRIBUTE {prefix}.codigo STRING ONE UNIQUE")
        stmts.append(f"ATTRIBUTE {prefix}.{desc_attr} STRING ONE")

    stmts.append("ATTRIBUTE empresa.cnpj_base STRING ONE UNIQUE")
    stmts.append("ATTRIBUTE empresa.razao_social STRING ONE")
    stmts.append("ATTRIBUTE empresa.natureza_juridica REF ONE")
    stmts.append("ATTRIBUTE empresa.qualificacao_resp REF ONE")
    stmts.append("ATTRIBUTE empresa.capital_social FLOAT ONE")
    stmts.append("ATTRIBUTE empresa.porte STRING ONE")
    stmts.append("ATTRIBUTE empresa.optante_simples STRING ONE")
    stmts.append("ATTRIBUTE empresa.data_opcao_simples STRING ONE")
    stmts.append("ATTRIBUTE empresa.data_exclusao_simples STRING ONE")
    stmts.append("ATTRIBUTE empresa.optante_mei STRING ONE")
    stmts.append("ATTRIBUTE empresa.data_opcao_mei STRING ONE")
    stmts.append("ATTRIBUTE empresa.data_exclusao_mei STRING ONE")

    stmts.append("ATTRIBUTE estab.cnpj_completo STRING ONE UNIQUE")
    stmts.append("ATTRIBUTE estab.empresa REF ONE")
    stmts.append("ATTRIBUTE estab.matriz_filial STRING ONE")
    stmts.append("ATTRIBUTE estab.nome_fantasia STRING ONE")
    stmts.append("ATTRIBUTE estab.situacao STRING ONE")
    stmts.append("ATTRIBUTE estab.data_situacao STRING ONE")
    stmts.append("ATTRIBUTE estab.motivo REF ONE")
    stmts.append("ATTRIBUTE estab.pais REF ONE")
    stmts.append("ATTRIBUTE estab.data_inicio_ativ STRING ONE")
    stmts.append("ATTRIBUTE estab.cnae_principal REF ONE")
    stmts.append("ATTRIBUTE estab.cnae_secundario REF MANY")
    stmts.append("ATTRIBUTE estab.tipo_logradouro STRING ONE")
    stmts.append("ATTRIBUTE estab.logradouro STRING ONE")
    stmts.append("ATTRIBUTE estab.numero STRING ONE")
    stmts.append("ATTRIBUTE estab.complemento STRING ONE")
    stmts.append("ATTRIBUTE estab.bairro STRING ONE")
    stmts.append("ATTRIBUTE estab.cep STRING ONE")
    stmts.append("ATTRIBUTE estab.uf STRING ONE")
    stmts.append("ATTRIBUTE estab.municipio REF ONE")
    stmts.append("ATTRIBUTE estab.ddd1 STRING ONE")
    stmts.append("ATTRIBUTE estab.telefone1 STRING ONE")
    stmts.append("ATTRIBUTE estab.ddd2 STRING ONE")
    stmts.append("ATTRIBUTE estab.telefone2 STRING ONE")
    stmts.append("ATTRIBUTE estab.email STRING ONE")

    stmts.append("ATTRIBUTE socio.empresa REF ONE")
    stmts.append("ATTRIBUTE socio.tipo_pessoa STRING ONE")
    stmts.append("ATTRIBUTE socio.nome STRING ONE")
    stmts.append("ATTRIBUTE socio.cpf_cnpj STRING ONE")
    stmts.append("ATTRIBUTE socio.qualificacao REF ONE")
    stmts.append("ATTRIBUTE socio.data_entrada STRING ONE")
    stmts.append("ATTRIBUTE socio.pais REF ONE")
    stmts.append("ATTRIBUTE socio.faixa_etaria STRING ONE")

    t0 = time.perf_counter()
    for stmt in stmts:
        client.execute(stmt)
    elapsed = time.perf_counter() - t0
    print(f"  declared {len(stmts)} attributes in {elapsed:.1f}s")


# ═══════════════════════════════════════════════════════════════════════════════
# Scheme batch helpers
# ═══════════════════════════════════════════════════════════════════════════════

S = Sym  # shorthand for Scheme symbol


def run_scheme_batch(client: EavtClient, body: list) -> int:
    """Execute a Scheme (begin ...) program in exec mode. Returns first EID."""
    program = [S("begin")] + body
    results = client.scheme(program, mode="exec")
    return results[0]["rows"][0][0]


# ═══════════════════════════════════════════════════════════════════════════════
# Loaders
# ═══════════════════════════════════════════════════════════════════════════════

def load_lookups(client: EavtClient, data_dir: Path, batch_size: int):
    """Load all lookup tables via Scheme batches."""
    for zip_prefix, prefix, desc_attr in LOOKUPS:
        zpath = find_zip(data_dir, zip_prefix)
        batch = []
        total = 0
        t0 = time.perf_counter()

        for row in rows_from_zip(zpath):
            if len(row) < 2 or not row[0]:
                continue
            batch.append(row)
            if len(batch) >= batch_size:
                _flush_lookup_batch(client, prefix, desc_attr, batch)
                total += len(batch)
                batch = []

        if batch:
            _flush_lookup_batch(client, prefix, desc_attr, batch)
            total += len(batch)

        elapsed = time.perf_counter() - t0
        print(f"  {prefix}: {total:,} entries in {elapsed:.1f}s "
              f"({total / max(elapsed, 0.001):,.0f}/s)", flush=True)


def _flush_lookup_batch(client, prefix, desc_attr, batch):
    body = []
    for row in batch:
        body.append([S("set!"), S("E"), [S("alloc-entity"), 4]])
        body.append([S("save"), S("E"), f"{prefix}.codigo", row[0]])
        body.append([S("save"), S("E"), f"{prefix}.{desc_attr}", row[1]])
    body.append([S("result"), S("E"), len(batch) * 2])
    run_scheme_batch(client, body)


def load_empresas(client: EavtClient, data_dir: Path, n: int, batch_size: int):
    zpath = find_zip(data_dir, "Empresas0")
    batch = []
    total = 0
    t0 = time.perf_counter()

    for row in rows_from_zip(zpath):
        if len(row) < 6:
            continue
        cnpj = row[0]
        if len(cnpj) != 8 or not cnpj.isdigit():
            continue
        batch.append(row)
        if len(batch) >= batch_size:
            _flush_empresa_batch(client, batch)
            total += len(batch)
            elapsed = time.perf_counter() - t0
            print(f"    {total:>10,} empresas  {elapsed:7.1f}s  "
                  f"({total / elapsed:,.0f}/s)", flush=True)
            batch = []
            if total >= n:
                break

    if batch and total < n:
        _flush_empresa_batch(client, batch)
        total += len(batch)

    elapsed = time.perf_counter() - t0
    print(f"  empresas: {total:,} in {elapsed:.1f}s ({total / max(elapsed, 0.001):,.0f}/s)",
          flush=True)
    return total


def _flush_empresa_batch(client, batch):
    body = []
    for row in batch:
        body.append([S("set!"), S("E"), [S("alloc-entity"), 4]])
        body.append([S("save"), S("E"), "empresa.cnpj_base", row[0]])
        if row[1]:
            body.append([S("save"), S("E"), "empresa.razao_social", row[1]])
        if row[2]:
            body.append([S("save"), S("E"), "empresa.natureza_juridica",
                         [S("lookup-entity"), "natureza.codigo", row[2]]])
        if row[3]:
            body.append([S("save"), S("E"), "empresa.qualificacao_resp",
                         [S("lookup-entity"), "qualificacao.codigo", row[3]]])
        if row[4]:
            body.append([S("save"), S("E"), "empresa.capital_social",
                         float(row[4].replace(",", "."))])
        if row[5]:
            body.append([S("save"), S("E"), "empresa.porte", row[5]])
    body.append([S("result"), S("E"), len(batch) * 6])
    run_scheme_batch(client, body)


def merge_simples(client: EavtClient, data_dir: Path):
    zpath = data_dir / "Simples__20260809T1834.zip"
    matched = 0
    scanned = 0
    t0 = time.perf_counter()

    for row in rows_from_zip(zpath):
        scanned += 1
        if scanned % 1_000_000 == 0:
            elapsed = time.perf_counter() - t0
            print(f"    scanned {scanned:,}, matched {matched:,}  "
                  f"({elapsed:.1f}s)", flush=True)
        if len(row) < 7:
            continue

        sets = []
        if row[1]:
            sets.append(("empresa.optante_simples", row[1]))
        if row[2] and row[2] != ZERO_DATE:
            sets.append(("empresa.data_opcao_simples", row[2]))
        if row[3] and row[3] != ZERO_DATE:
            sets.append(("empresa.data_exclusao_simples", row[3]))
        if row[4]:
            sets.append(("empresa.optante_mei", row[4]))
        if row[5] and row[5] != ZERO_DATE:
            sets.append(("empresa.data_opcao_mei", row[5]))
        if row[6] and row[6] != ZERO_DATE:
            sets.append(("empresa.data_exclusao_mei", row[6]))
        if not sets:
            continue

        body = [
            [S("set!"), S("E"), [S("lookup-entity"), "empresa.cnpj_base", row[0]]],
        ]
        for attr, val in sets:
            body.append([S("when"), S("E"),
                         [S("save"), S("E"), attr, val]])
        body.append([S("result"), S("E"), len(sets)])

        try:
            run_scheme_batch(client, body)
            matched += 1
        except RuntimeError:
            pass

    elapsed = time.perf_counter() - t0
    print(f"  simples: {matched:,} matched (scanned {scanned:,}) in {elapsed:.1f}s", flush=True)


def load_estabs(client: EavtClient, data_dir: Path, batch_size: int, max_scan: int = 0):
    zpath = find_zip(data_dir, "Estabelecimentos0")
    batch = []
    total = 0
    scanned = 0
    t0 = time.perf_counter()

    for row in rows_from_zip(zpath):
        scanned += 1
        if max_scan > 0 and scanned > max_scan:
            break
        if scanned % 1_000_000 == 0:
            elapsed = time.perf_counter() - t0
            print(f"    scanned {scanned:,}, saved {total:,} estabs  "
                  f"({elapsed:.1f}s)", flush=True)
        if len(row) < 30:
            continue
        cnpj_base = row[0]
        if len(cnpj_base) != 8 or not cnpj_base.isdigit():
            continue
        batch.append(row)
        if len(batch) >= batch_size:
            _flush_estab_batch(client, batch)
            total += len(batch)
            batch = []

    if batch:
        _flush_estab_batch(client, batch)
        total += len(batch)

    elapsed = time.perf_counter() - t0
    print(f"  estabelecimentos: {total:,} (scanned {scanned:,}) in {elapsed:.1f}s "
          f"({total / max(elapsed, 0.001):,.0f}/s)", flush=True)


def _flush_estab_batch(client, batch):
    body = []
    for row in batch:
        cnpj_base = row[0]
        cnpj_full = row[0] + row[1].zfill(4) + row[2].zfill(2)

        body.append([S("set!"), S("E"), [S("alloc-entity"), 4]])
        body.append([S("save"), S("E"), "estab.cnpj_completo", cnpj_full])
        body.append([S("save"), S("E"), "estab.empresa",
                     [S("lookup-entity"), "empresa.cnpj_base", cnpj_base]])
        if row[3]:
            body.append([S("save"), S("E"), "estab.matriz_filial", row[3]])
        if row[4]:
            body.append([S("save"), S("E"), "estab.nome_fantasia", row[4]])
        if row[5]:
            body.append([S("save"), S("E"), "estab.situacao", row[5]])
        if row[6] and row[6] != ZERO_DATE:
            body.append([S("save"), S("E"), "estab.data_situacao", row[6]])
        if row[7]:
            body.append([S("save"), S("E"), "estab.motivo",
                         [S("lookup-entity"), "motivo.codigo", row[7]]])
        if row[9]:
            body.append([S("save"), S("E"), "estab.pais",
                         [S("lookup-entity"), "pais.codigo", row[9]]])
        if row[10] and row[10] != ZERO_DATE:
            body.append([S("save"), S("E"), "estab.data_inicio_ativ", row[10]])
        if row[11]:
            body.append([S("save"), S("E"), "estab.cnae_principal",
                         [S("lookup-entity"), "cnae.codigo", row[11]]])
        if row[12]:
            for code in row[12].split(","):
                code = code.strip()
                if code:
                    body.append([S("save"), S("E"), "estab.cnae_secundario",
                                 [S("lookup-entity"), "cnae.codigo", code]])
        if row[13]:
            body.append([S("save"), S("E"), "estab.tipo_logradouro", row[13]])
        if row[14]:
            body.append([S("save"), S("E"), "estab.logradouro", row[14]])
        if row[15]:
            body.append([S("save"), S("E"), "estab.numero", row[15]])
        if row[16]:
            body.append([S("save"), S("E"), "estab.complemento", row[16]])
        if row[17]:
            body.append([S("save"), S("E"), "estab.bairro", row[17]])
        if row[18]:
            body.append([S("save"), S("E"), "estab.cep", row[18]])
        if row[19]:
            body.append([S("save"), S("E"), "estab.uf", row[19]])
        if row[20]:
            body.append([S("save"), S("E"), "estab.municipio",
                         [S("lookup-entity"), "municipio.codigo", row[20]]])
        if row[21]:
            body.append([S("save"), S("E"), "estab.ddd1", row[21]])
        if row[22]:
            body.append([S("save"), S("E"), "estab.telefone1", row[22]])
        if row[23]:
            body.append([S("save"), S("E"), "estab.ddd2", row[23]])
        if row[24]:
            body.append([S("save"), S("E"), "estab.telefone2", row[24]])
        if row[27]:
            body.append([S("save"), S("E"), "estab.email", row[27]])

    body.append([S("result"), S("E"), len(batch) * 20])
    run_scheme_batch(client, body)


def load_socios(client: EavtClient, data_dir: Path, batch_size: int, max_scan: int = 0):
    zpath = find_zip(data_dir, "Socios0")
    batch = []
    total = 0
    scanned = 0
    t0 = time.perf_counter()

    for row in rows_from_zip(zpath):
        if max_scan > 0 and scanned > max_scan:
            break
        if len(row) < 11:
            continue
        cnpj_base = row[0]
        if len(cnpj_base) != 8 or not cnpj_base.isdigit():
            continue
        scanned += 1
        batch.append(row)
        if len(batch) >= batch_size:
            _flush_socio_batch(client, batch)
            total += len(batch)
            elapsed = time.perf_counter() - t0
            print(f"    {total:>10,} socios  {elapsed:7.1f}s  "
                  f"({total / elapsed:,.0f}/s)", flush=True)
            batch = []

    if batch:
        _flush_socio_batch(client, batch)
        total += len(batch)

    elapsed = time.perf_counter() - t0
    print(f"  socios: {total:,} in {elapsed:.1f}s ({total / max(elapsed, 0.001):,.0f}/s)",
          flush=True)


def _flush_socio_batch(client, batch):
    body = []
    for row in batch:
        cnpj_base = row[0]
        body.append([S("set!"), S("E"), [S("alloc-entity"), 4]])
        body.append([S("save"), S("E"), "socio.empresa",
                     [S("lookup-entity"), "empresa.cnpj_base", cnpj_base]])
        if row[1]:
            body.append([S("save"), S("E"), "socio.tipo_pessoa", row[1]])
        if row[2]:
            body.append([S("save"), S("E"), "socio.nome", row[2]])
        if row[3]:
            body.append([S("save"), S("E"), "socio.cpf_cnpj", row[3]])
        if row[4]:
            body.append([S("save"), S("E"), "socio.qualificacao",
                         [S("lookup-entity"), "qualificacao.codigo", row[4]]])
        if row[5] and row[5] != ZERO_DATE:
            body.append([S("save"), S("E"), "socio.data_entrada", row[5]])
        if row[6]:
            body.append([S("save"), S("E"), "socio.pais",
                         [S("lookup-entity"), "pais.codigo", row[6]]])
        if row[10]:
            body.append([S("save"), S("E"), "socio.faixa_etaria", row[10]])

    body.append([S("result"), S("E"), len(batch) * 8])
    run_scheme_batch(client, body)


# ═══════════════════════════════════════════════════════════════════════════════
# Demo queries
# ═══════════════════════════════════════════════════════════════════════════════

def demo(client: EavtClient):
    print("\n=== Demo queries ===")

    t0 = time.perf_counter()
    rows = client.execute(
        "SELECT d1.empresa.cnpj_base, d1.empresa.razao_social")
    if not rows:
        print("  (empty DB)")
        return
    cnpj, rs = rows[0]
    print(f"first empresa: cnpj={cnpj} rs={rs[:40]!r}  "
          f"({(time.perf_counter() - t0) * 1000:.2f}ms)")

    t0 = time.perf_counter()
    rows = client.execute("SELECT eid('empresa.cnpj_base', %1)", cnpj)
    eid = rows[0][0]
    print(f"eid() lookup -> {eid}  ({(time.perf_counter() - t0) * 1000:.2f}ms)")

    t0 = time.perf_counter()
    rows = client.execute(
        "SELECT d1.estab.cnpj_completo, d1.estab.nome_fantasia "
        "WHERE d1.estab.empresa = %1", eid)
    print(f"estabs of empresa: {len(rows)}  "
          f"({(time.perf_counter() - t0) * 1000:.2f}ms)")
    for r in rows[:5]:
        print(f"    {r[0]}  fantasia={str(r[1])[:40]!r}")

    t0 = time.perf_counter()
    rows = client.execute(
        "SELECT d1.socio.nome WHERE d1.socio.empresa = %1", eid)
    print(f"socios: {len(rows)}  "
          f"({(time.perf_counter() - t0) * 1000:.2f}ms)")
    for r in rows[:5]:
        print(f"    {str(r[0])[:50]!r}")

    t0 = time.perf_counter()
    rows = client.execute(
        "SELECT d1.empresa.razao_social, d1.empresa.capital_social "
        "WHERE d1.empresa.capital_social >= %1", 1000.0)
    print(f"capital >= 1000: {len(rows)}  "
          f"({(time.perf_counter() - t0) * 1000:.2f}ms)")
    for r in rows[:5]:
        print(f"    {str(r[0])[:40]!r}  capital={r[1]:,.2f}")


# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    ap = argparse.ArgumentParser(description="Load Receita CNPJ data via query server")
    ap.add_argument("--n", type=int, default=1_000_000,
                    help="number of empresas to load (default 1M)")
    ap.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
    ap.add_argument("--sock", default=None, help="UDS socket path")
    ap.add_argument("--batch", type=int, default=BATCH_SIZE,
                    help=f"Scheme batch size (default {BATCH_SIZE})")
    ap.add_argument("--demo-only", action="store_true",
                    help="skip loading, run demo queries on existing DB")
    ap.add_argument("--skip-simples", action="store_true",
                    help="skip simples merge (huge file)")
    ap.add_argument("--max-estabs", type=int, default=0,
                    help="max estabelecimentos to scan (0=all)")
    ap.add_argument("--max-socios", type=int, default=0,
                    help="max socios to scan (0=all)")
    args = ap.parse_args()

    client = EavtClient(args.sock)
    print(f"Connected to query server")

    if args.demo_only:
        demo(client)
        client.close()
        return 0

    print("== Declaring schema ==")
    declare_schema(client)

    print(f"\n== Lookups (data: {args.data_dir}) ==")
    load_lookups(client, args.data_dir, args.batch)

    print(f"\n== Empresas0 (first {args.n:,}) ==")
    load_empresas(client, args.data_dir, args.n, args.batch)

    if not args.skip_simples:
        print("\n== Simples (merge into empresas) ==")
        merge_simples(client, args.data_dir)
    else:
        print("\n== Simples (skipped) ==")

    print("\n== Estabelecimentos0 (filtered) ==")
    load_estabs(client, args.data_dir, args.batch, args.max_estabs)

    print("\n== Socios0 (filtered) ==")
    load_socios(client, args.data_dir, args.batch, args.max_socios)

    demo(client)
    client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
