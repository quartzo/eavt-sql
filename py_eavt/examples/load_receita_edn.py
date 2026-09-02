#!/usr/bin/env python3
"""load_receita_edn.py — Load Receita Federal CNPJ data via EDN tx-data + Datalog.

Everything goes through the tx protocol (docs/tx-protocol.md):
- Schema: tx schema-as-data ([[:db/add 0 :db/ident :ns/attr] ...])
- Writes:  tx :db/add with tempids anchored on :db.unique/identity attrs
- Queries: Datalog EDN vectors via q()

No SQL — the gateway only accepts datalog and tx requests.

Usage:
    uv run python py_eavt/examples/load_receita_edn.py --n 5000    # quick test
    uv run python py_eavt/examples/load_receita_edn.py              # full 1M empresas

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

from eavt_client.client import EavtClient, Kw  # noqa: E402

DEFAULT_DATA = Path("/home/fabio/dev/dagster_flows/tests_data/receita_zip")
BATCH_SIZE = 500
ZERO_DATE = "00000000"

# ── EDN tx helpers ────────────────────────────────────────────────────────────

def kw(name: str):
    """EDN keyword — Kw strips the leading colon and maps to ext 0x06."""
    return Kw(name.lstrip(":"))

def op_add(e, attr, val):
    """[:db/add e :attr val] — one op vector."""
    return [kw("db/add"), e, kw(attr), val]

def tx_ops(client: EavtClient, ops: list[list]) -> dict:
    """Send a batch of tx ops atomically. Returns the tx-report."""
    return client.tx(ops)

def tx_attr(name: str, vt: str, many: bool = False, unique: bool = False) -> list:
    """Schema-as-data ops for one attribute."""
    ops = [
        op_add(0, "db/ident", kw(name)),
        op_add(0, "db/valueType", kw(f"db.type/{vt}")),
        op_add(0, "db/cardinality", kw("db.cardinality/many" if many else "db.cardinality/one")),
    ]
    if unique:
        ops.append(op_add(0, "db/unique", kw("db.unique/identity")))
    return ops

def tx_save(eid: int, attr: str, val):
    """[:db/add eid :ns/attr val] — one save op (eid is an int, not tempid)."""
    return op_add(eid, attr, val)

def tx_upsert(attr: str, val) -> list:
    """Upsert via tempid: the tx interpreter resolves the entity by the
    unique attr anchor. Returns [[:db/add -1 :ns/attr val]]."""
    return op_add(-1, attr, val)

# ── Schema declaration ────────────────────────────────────────────────────────

SCHEMA_ATTRS = [
    # lookups
    ("cnae/codigo", "string", True, True), ("cnae/descricao", "string", False, False),
    ("municipio/codigo", "string", True, True), ("municipio/nome", "string", False, False),
    ("natureza/codigo", "string", True, True), ("natureza/descricao", "string", False, False),
    ("qualificacao/codigo", "string", True, True), ("qualificacao/descricao", "string", False, False),
    ("pais/codigo", "string", True, True), ("pais/nome", "string", False, False),
    ("motivo/codigo", "string", True, True), ("motivo/descricao", "string", False, False),
    # empresa
    ("empresa/cnpj_base", "string", False, True),
    ("empresa/razao_social", "string", False, False),
    ("empresa/natureza_juridica", "ref", False, False),
    ("empresa/qualificacao_resp", "ref", False, False),
    ("empresa/capital_social", "float", False, False),
    ("empresa/porte", "string", False, False),
    ("empresa/optante_simples", "string", False, False),
    ("empresa/data_opcao_simples", "string", False, False),
    ("empresa/data_exclusao_simples", "string", False, False),
    ("empresa/optante_mei", "string", False, False),
    ("empresa/data_opcao_mei", "string", False, False),
    ("empresa/data_exclusao_mei", "string", False, False),
    # estab
    ("estab/cnpj_completo", "string", False, True),
    ("estab/empresa", "ref", False, False),
    ("estab/matriz_filial", "string", False, False),
    ("estab/nome_fantasia", "string", False, False),
    ("estab/situacao", "string", False, False),
    ("estab/data_situacao", "string", False, False),
    ("estab/motivo", "ref", False, False),
    ("estab/pais", "ref", False, False),
    ("estab/data_inicio_ativ", "string", False, False),
    ("estab/cnae_principal", "ref", False, False),
    ("estab/cnae_secundario", "ref", True, False),
    ("estab/tipo_logradouro", "string", False, False),
    ("estab/logradouro", "string", False, False),
    ("estab/numero", "string", False, False),
    ("estab/complemento", "string", False, False),
    ("estab/bairro", "string", False, False),
    ("estab/cep", "string", False, False),
    ("estab/uf", "string", False, False),
    ("estab/municipio", "ref", False, False),
    ("estab/ddd1", "string", False, False),
    ("estab/telefone1", "string", False, False),
    ("estab/ddd2", "string", False, False),
    ("estab/telefone2", "string", False, False),
    ("estab/email", "string", False, False),
    # socio
    ("socio/empresa", "ref", False, False),
    ("socio/tipo_pessoa", "string", False, False),
    ("socio/nome", "string", False, False),
    ("socio/cpf_cnpj", "string", False, False),
    ("socio/qualificacao", "ref", False, False),
    ("socio/data_entrada", "string", False, False),
    ("socio/pais", "ref", False, False),
    ("socio/faixa_etaria", "string", False, False),
]


def declare_schema(client) -> None:
    """Declare all attributes via tx schema-as-data (one tx for all).
    Each attr gets a unique eid — the interpreter groups schema datoms by eid."""
    ops = []
    for i, (name, vt, many, unique) in enumerate(SCHEMA_ATTRS):
        eid = 1000 + i
        ops.append(op_add(eid, "db/ident", kw(name)))
        ops.append(op_add(eid, "db/valueType", kw(f"db.type/{vt}")))
        ops.append(op_add(eid, "db/cardinality", kw("db.cardinality/many" if many else "db.cardinality/one")))
        if unique:
            ops.append(op_add(eid, "db/unique", kw("db.unique/identity")))
    t0 = time.perf_counter()
    client.tx(ops)
    elapsed = time.perf_counter() - t0
    print(f"  declared {len(SCHEMA_ATTRS)} attributes in {elapsed:.1f}s")

# ── File reading ──────────────────────────────────────────────────────────────

def rows_from_zip(zpath: Path):
    """Yield rows from a Receita zip (latin-1, ';'-separated, no header)."""
    with zipfile.ZipFile(zpath) as zf:
        name = zf.namelist()[0]
        with zf.open(name) as f:
            reader = csv.reader(io.TextIOWrapper(f, encoding="latin-1"),
                                delimiter=";")
            yield from reader

def find_zip(data_dir: Path, prefix: str) -> Path:
    for p in data_dir.glob(f"{prefix}*.zip"):
        return p
    raise FileNotFoundError(f"no {prefix}*.zip in {data_dir}")

# ── Batch tx helpers ──────────────────────────────────────────────────────────

def tx_batch(client, ops: list[list]) -> dict:
    """Send a batch of tx ops atomically. Returns the tx-report."""
    if not ops:
        return {}
    return client.tx(ops)

# ── Loaders ───────────────────────────────────────────────────────────────────

LOOKUPS = [
    ("Cnaes", "cnae", "descricao"),
    ("Municipios", "municipio", "nome"),
    ("Naturezas", "natureza", "descricao"),
    ("Qualificacoes", "qualificacao", "descricao"),
    ("Paises", "pais", "nome"),
    ("Motivos", "motivo", "descricao"),
]


def load_lookups(client, data_dir: Path, batch_size: int):
    """Load all lookup tables via tx batches with tempid upsert."""
    for zip_prefix, prefix, desc_attr in LOOKUPS:
        zpath = find_zip(data_dir, zip_prefix)
        ops: list[list] = []
        total = 0
        t0 = time.perf_counter()

        for row in rows_from_zip(zpath):
            if len(row) < 2 or not row[0]:
                continue
            # tempid -1 anchored on the unique attr (codigo) — get-or-create
            ops.append(op_add(-1, f"{prefix}/codigo", row[0]))
            if row[1]:
                ops.append(op_add(-1, f"{prefix}/{desc_attr}", row[1]))
            if len(ops) >= batch_size * 2:
                tx_batch(client, ops)
                total += len(ops) // 2
                ops = []
        if ops:
            tx_batch(client, ops)
            total += len(ops) // 2

        elapsed = time.perf_counter() - t0
        print(f"  {prefix}: {total:,} entries in {elapsed:.1f}s "
              f"({total / max(elapsed, 0.001):,.0f}/s)", flush=True)


def load_empresas(client, data_dir: Path, n: int, batch_size: int) -> int:
    """Load Empresas0 via tx :db/add with tempid upsert on cnpj_base."""
    zpath = find_zip(data_dir, "Empresas0")
    ops: list[list] = []
    total = 0
    t0 = time.perf_counter()

    for row in rows_from_zip(zpath):
        if len(row) < 6:
            continue
        cnpj = row[0]
        if len(cnpj) != 8 or not cnpj.isdigit():
            continue
        ops.append(op_add(-1, "empresa/cnpj_base", row[0]))
        if row[1]:
            ops.append(op_add(-1, "empresa/razao_social", row[1]))
        if row[2]:
            ops.append(op_add(-1, "empresa/natureza_juridica", row[2]))
        if row[3]:
            ops.append(op_add(-1, "empresa/qualificacao_resp", row[3]))
        if row[4]:
            ops.append(op_add(-1, "empresa/capital_social", float(row[4].replace(",", "."))))
        if row[5]:
            ops.append(op_add(-1, "empresa/porte", row[5]))
        total += 1
        if total % batch_size == 0:
            tx_batch(client, ops)
            elapsed = time.perf_counter() - t0
            print(f"    {total:>10,} empresas  {elapsed:7.1f}s  "
                  f"({total / elapsed:,.0f}/s)", flush=True)
            ops = []
        if total >= n:
            break
    if ops and total < n:
        tx_batch(client, ops)

    elapsed = time.perf_counter() - t0
    print(f"  empresas: {total:,} in {elapsed:.1f}s ({total / max(elapsed, 0.001):,.0f}/s)",
          flush=True)
    return total

# ── Simples merge (goc pattern → tx upsert by unique attr) ────────────────────

ZERO_DATE = "00000000"

def merge_simples(client, data_dir: Path, batch_size: int = BATCH_SIZE) -> tuple[int, int]:
    """Simples merge via tx upsert (tempid on empresa/cnpj_base unique anchor)."""
    zpath = find_zip(data_dir, "Simples")
    matched = 0
    scanned = 0
    t0 = time.perf_counter()
    ops: list[list] = []

    for row in rows_from_zip(zpath):
        scanned += 1
        if scanned % 1_000_000 == 0:
            elapsed = time.perf_counter() - t0
            print(f"    scanned {scanned:,}, matched {matched:,}  "
                  f"({elapsed:.1f}s)", flush=True)
        if len(row) < 7:
            continue
        sets = []
        if row[1]: sets.append(("empresa/optante_simples", row[1]))
        if row[2] and row[2] != ZERO_DATE: sets.append(("empresa/data_opcao_simples", row[2]))
        if row[3] and row[3] != ZERO_DATE: sets.append(("empresa/data_exclusao_simples", row[3]))
        if row[4]: sets.append(("empresa/optante_mei", row[4]))
        if row[5] and row[5] != ZERO_DATE: sets.append(("empresa/data_opcao_mei", row[5]))
        if row[6] and row[6] != ZERO_DATE: sets.append(("empresa/data_exclusao_mei", row[6]))
        if not sets:
            continue
        # upsert by cnpj_base unique anchor
        ops.append(op_add(-1, "empresa/cnpj_base", row[0]))
        for attr, val in sets:
            ops.append(op_add(-1, attr, val))
        if len(ops) >= batch_size * 2:
            tx_batch(client, ops)
            matched += len(ops) // (len(sets) + 1)
            ops = []
    if ops:
        tx_batch(client, ops)
        matched += 1
    elapsed = time.perf_counter() - t0
    print(f"  simples: {matched:,} matched (scanned {scanned:,}) in {elapsed:.1f}s "
          f"({matched / max(elapsed, 0.001):,.0f}/s)", flush=True)
    return matched, scanned

# ── Estabelecimentos bulk ────────────────────────────────────────────────────

ESTAB_STR_ATTRS = [
    (0, "estab/cnpj_completo"), (3, "estab/matriz_filial"), (4, "estab/nome_fantasia"),
    (5, "estab.situacao"), (6, "estab.data_situacao"),
    (10, "estab.data_inicio_ativ"), (13, "estab.tipo_logradouro"),
    (14, "estab.logradouro"), (15, "estab.numero"),
    (16, "estab.complemento"), (17, "estab.bairro"),
    (18, "estab.cep"), (19, "estab.uf"), (21, "estab.ddd1"),
    (22, "estab.telefone1"), (23, "estab.ddd2"),
    (24, "estab.telefone2"), (27, "estab.email"),
]
ESTAB_REF_ATTRS = [
    (0, "estab.empresa", "empresa/cnpj_base"),
    (7, "estab.motivo", "motivo/codigo"),
    (9, "estab.pais", "pais/codigo"),
    (11, "estab.cnae_principal", "cnae/codigo"),
    (20, "estab.municipio", "municipio/codigo"),
]


def _flush_estab_batch(client, batch):
    """Write estabs via tx :db/add with tempid upsert on cnpj_completo."""
    ops: list[list] = []
    for row in batch:
        cnpj_full = row[0] + row[1].zfill(4) + row[2].zfill(2)
        ops.append(op_add(-1, "estab/cnpj_completo", cnpj_full))
        ops.append(op_add(-1, "empresa/cnpj_base", row[0]))
        for idx, attr in ESTAB_STR_ATTRS:
            if idx == 0: continue  # already added above
            if row[idx]:
                ops.append(op_add(-1, attr, row[idx]))
        for idx, attr, uattr in ESTAB_REF_ATTRS:
            code = row[idx] if idx != 0 else row[0]
            if code and attr != "estab.empresa":
                ops.append(op_add(-1, attr, kw(code)))
        if row[12]:
            for code in row[12].split(","):
                code = code.strip()
                if code:
                    ops.append(op_add(-1, "estab/cnae_secundario", kw(code)))
    tx_batch(client, ops)


def load_estabs_bulk(client, data_dir: Path, max_rows: int,
                     batch_size: int) -> tuple[int, int]:
    """Estabelecimentos via tx :db/add with tempid upsert on cnpj_completo."""
    zpath = find_zip(data_dir, "Estabelecimentos0")
    saved = scanned = 0
    batch: list = []
    t0 = time.perf_counter()
    for row in rows_from_zip(zpath):
        scanned += 1
        if len(row) < 30 or len(row[0]) != 8 or not row[0].isdigit():
            continue
        batch.append(row)
        if len(batch) >= batch_size:
            _flush_estab_batch(client, batch)
            saved += len(batch)
            batch = []
            if saved >= max_rows:
                break
    if batch and saved < max_rows:
        _flush_estab_batch(client, batch)
        saved += len(batch)
    elapsed = time.perf_counter() - t0
    print(f"  estabs(tx): {saved:,} linhas gravadas "
          f"(scanned {scanned:,}) in {elapsed:.1f}s", flush=True)
    return saved, scanned


def _flush_socio_batch(client, batch):
    """Write socios via tx :db/add with tempid upsert on cnpj_base."""
    ops: list[list] = []
    for row in batch:
        ops.append(op_add(-1, "socio/empresa", row[0]))
        if row[1]: ops.append(op_add(-1, "socio/tipo_pessoa", row[1]))
        if row[2]: ops.append(op_add(-1, "socio/nome", row[2]))
        if row[3]: ops.append(op_add(-1, "socio/cpf_cnpj", row[3]))
        if row[4]: ops.append(op_add(-1, "socio/qualificacao", kw(row[4])))
        if row[5] and row[5] != ZERO_DATE: ops.append(op_add(-1, "socio/data_entrada", row[5]))
        if row[6]: ops.append(op_add(-1, "socio/pais", kw(row[6])))
        if row[10]: ops.append(op_add(-1, "socio/faixa_etaria", row[10]))
    tx_batch(client, ops)


def load_socios(client, data_dir: Path, batch_size: int, max_scan: int = 0) -> tuple[int, int]:
    zpath = find_zip(data_dir, "Socios0")
    batch: list = []
    total = 0
    scanned = 0
    t0 = time.perf_counter()
    for row in rows_from_zip(zpath):
        if max_scan > 0 and scanned > max_scan: break
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
            batch = []
    if batch:
        _flush_socio_batch(client, batch)
        total += len(batch)
    elapsed = time.perf_counter() - t0
    print(f"  socios: {total:,} in {elapsed:.1f}s", flush=True)
    return total, scanned

def first_n_cnpjs(data_dir: Path, n: int) -> list[str]:
    out = []
    for row in rows_from_zip(find_zip(data_dir, "Empresas0")):
        if len(row) >= 6 and len(row[0]) == 8 and row[0].isdigit():
            out.append(row[0])
            if len(out) >= n:
                break
    return out

# ── Probes ────────────────────────────────────────────────────────────────────

def stats(samples: list[float]) -> dict:
    import statistics
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


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Load Receita CNPJ via EDN tx + Datalog")
    ap.add_argument("--n", type=int, default=1_000_000)
    ap.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
    ap.add_argument("--sock", default=None)
    ap.add_argument("--batch", type=int, default=BATCH_SIZE)
    ap.add_argument("--demo-only", action="store_true")
    ap.add_argument("--skip-simples", action="store_true")
    ap.add_argument("--skip-estabs", action="store_true")
    ap.add_argument("--skip-socios", action="store_true")
    ap.add_argument("--max-estabs", type=int, default=0)
    ap.add_argument("--max-socios", type=int, default=0)
    args = ap.parse_args()

    client = EavtClient(args.sock)
    print("Connected to query server")

    if args.demo_only:
        rows = client.q("[:find ?cnpj ?rs :where [?e :empresa/cnpj_base ?cnpj] [?e :empresa/razao_social ?rs]]")
        if not rows:
            print("  (empty DB)")
            return 0
        cnpj, rs = rows[0]
        print(f"first empresa: cnpj={cnpj} rs={rs[:40]!r}")
        rows = client.q("[:find ?e :where [?e :empresa/cnpj_base ?cnpj]]", cnpj)
        print(f"eid lookup: {rows[0][0]}")
        rows = client.q("[:find ?fant :where [?e :estab/empresa ?eid] [?e :estab.nome_fantasia ?fant]]", eid)
        print(f"estabs: {len(rows)}")
        client.close()
        return 0

    print("== Declaring schema (tx schema-as-data) ==")
    declare_schema(client)

    print(f"\n== Lookups (data: {args.data_dir}) ==")
    load_lookups(client, args.data_dir, args.batch)

    print(f"\n== Empresas0 (first {args.n:,}) ==")
    load_empresas(client, args.data_dir, args.n, args.batch)

    if not args.skip_simples:
        print("\n== Simples (merge via tx upsert) ==")
        merge_simples(client, args.data_dir, args.batch)

    print("\n== Estabelecimentos0 ==")
    if not args.skip_estabs:
        load_estabs_bulk(client, args.data_dir, args.max_estabs or 0, args.batch)

    print("\n== Socios0 ==")
    load_socios(client, args.data_dir, args.batch, args.max_socios)

    client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
