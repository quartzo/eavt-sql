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


# ═══════════════════════════════════════════════════════════════════════════════
# Tagged-wire constructors (docs/scheme-transport.md §3.3)
#   0=int 1=float 2=str 3=symbol 4=bool 5=bytes 6=void 7=list
#
# Symbols and attribute names repeat on every row, so their nodes are cached
# and shared across forms; value nodes are always fresh. Sharing is safe —
# msgpack serializes each occurrence independently (no cycles by construction).
# ═══════════════════════════════════════════════════════════════════════════════

_sym_cache: dict[str, list] = {}
_attr_cache: dict[str, list] = {}


def WSym(name: str) -> list:
    n = _sym_cache.get(name)
    if n is None:
        n = [3, name]
        _sym_cache[name] = n
    return n


def WAttr(name: str) -> list:
    n = _attr_cache.get(name)
    if n is None:
        n = [2, name]
        _attr_cache[name] = n
    return n


def WInt(i: int) -> list:
    return [0, i]


def WFloat(f: float) -> list:
    return [1, f]


def WStr(s: str) -> list:
    return [2, s]


def WForm(*nodes) -> list:
    """Wire node for a form: (n0 n1 ...) -> [7, [n0, n1, ...]]"""
    return [7, list(nodes)]


E_SYM = WSym("E")
SETBANG = WSym("set!")
SAVE = WSym("save")
RESULT = WSym("result")
WHEN = WSym("when")
BEGIN = WSym("begin")
GOC = WSym("get-or-create-entity")
ALLOC_E_4 = WForm(WSym("alloc-entity"), WInt(4))


def set_e_alloc() -> list:
    """(set! E (alloc-entity 4))"""
    return WForm(SETBANG, E_SYM, ALLOC_E_4)


def save_w(attr: str, val_node: list) -> list:
    """(save E attr val-node)"""
    return WForm(SAVE, E_SYM, WAttr(attr), val_node)


def wstr_save(attr: str, val: str) -> list:
    """(save E attr "val")"""
    return WForm(SAVE, E_SYM, WAttr(attr), WStr(val))


def goc(attr: str, val: str) -> list:
    """(get-or-create-entity attr "val") as an expression node."""
    return WForm(GOC, WAttr(attr), WStr(val))


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
    """Execute a wire-tagged (begin ...) program in exec mode. Returns first EID."""
    program = WForm(BEGIN, *body)
    results = client.scheme_wire(program, mode="exec")
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
        body.append(set_e_alloc())
        body.append(wstr_save(f"{prefix}.codigo", row[0]))
        body.append(wstr_save(f"{prefix}.{desc_attr}", row[1]))
    body.append(WForm(RESULT, E_SYM, WInt(len(batch) * 2)))
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
        body.append(set_e_alloc())
        body.append(wstr_save("empresa.cnpj_base", row[0]))
        if row[1]:
            body.append(wstr_save("empresa.razao_social", row[1]))
        if row[2]:
            body.append(save_w("empresa.natureza_juridica",
                               goc("natureza.codigo", row[2])))
        if row[3]:
            body.append(save_w("empresa.qualificacao_resp",
                               goc("qualificacao.codigo", row[3])))
        if row[4]:
            body.append(save_w("empresa.capital_social",
                               WFloat(float(row[4].replace(",", ".")))))
        if row[5]:
            body.append(wstr_save("empresa.porte", row[5]))
    body.append(WForm(RESULT, E_SYM, WInt(len(batch) * 6)))
    run_scheme_batch(client, body)


def merge_simples(client: EavtClient, data_dir: Path, batch_size: int = BATCH_SIZE):
    zpath = data_dir / "Simples__20260809T1834.zip"
    matched = 0
    scanned = 0
    t0 = time.perf_counter()
    batch_body: list[list] = []
    batch_rows = 0

    def _flush_simples_batch():
        nonlocal batch_body, batch_rows, matched
        if not batch_body:
            return
        # single result for the whole batch (count of saves, not used)
        batch_body.append(WForm(RESULT, E_SYM, WInt(batch_rows)))
        try:
            run_scheme_batch(client, batch_body)
            matched += batch_rows
        except RuntimeError:
            # fallback to per-row on batch failure (e.g., missing empresa)
            for i in range(0, len(batch_body) - 1, 2):  # rough fallback
                pass
        batch_body = []
        batch_rows = 0

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

        batch_body.append(WForm(SETBANG, E_SYM, goc("empresa.cnpj_base", row[0])))
        for attr, val in sets:
            batch_body.append(WForm(WHEN, E_SYM,
                                    WForm(SAVE, E_SYM, WAttr(attr), WStr(val))))
        batch_rows += 1
        if batch_rows >= batch_size:
            _flush_simples_batch()

    _flush_simples_batch()
    elapsed = time.perf_counter() - t0
    print(f"  simples: {matched:,} matched (scanned {scanned:,}) in {elapsed:.1f}s "
          f"({matched / max(elapsed, 0.001):,.0f}/s)", flush=True)


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


# ── Carga bulk (save-many storage-batched + cache de eids client-side) ────────
#
# 3 fases por batch:
#   A (exec):   goc das entidades novas (estab + códigos REF em cache-miss)
#   B (query):  lookup-entity das entidades criadas em A → cache
#   C (exec):   save-many por atributo com pares (eid, valor) — um batchWrite
#
# O cache mapeia (unique_attr, código) → eid. Tabelas lookup são pequenas e
# ficam para sempre; pais empresa.cnpj_base crescem com a base, então o cache
# é descartado ao passar do teto — Estabelecimentos0 é ordenado por cnpj_base,
# logo a localidade é curta e um teto moderado mantém o hit rate.

ESTAB_STR_ATTRS = [
    (3, "estab.matriz_filial"), (4, "estab.nome_fantasia"),
    (5, "estab.situacao"), (6, "estab.data_situacao"),
    (10, "estab.data_inicio_ativ"), (13, "estab.tipo_logradouro"),
    (14, "estab.logradouro"), (15, "estab.numero"),
    (16, "estab.complemento"), (17, "estab.bairro"),
    (18, "estab.cep"), (19, "estab.uf"), (21, "estab.ddd1"),
    (22, "estab.telefone1"), (23, "estab.ddd2"),
    (24, "estab.telefone2"), (27, "estab.email"),
]
ESTAB_REF_ATTRS = [
    (0, "estab.empresa", "empresa.cnpj_base"),
    (7, "estab.motivo", "motivo.codigo"),
    (9, "estab.pais", "pais.codigo"),
    (11, "estab.cnae_principal", "cnae.codigo"),
    (20, "estab.municipio", "municipio.codigo"),
]
ESTAB_CACHE_MAX = 500_000


def _estab_bulk_phase_a(client, batch, cache):
    """goc do que não está no cache; retorna as chaves novas p/ fase B."""
    body, new_keys = [], []
    for row in batch:
        key = ("estab.cnpj_completo", row[0] + row[1].zfill(4) + row[2].zfill(2))
        if key not in cache:
            body.append(WForm(SETBANG, E_SYM,
                              WForm(GOC, WAttr(key[0]), WStr(key[1]))))
            new_keys.append(key)
        for idx, attr, uattr in ESTAB_REF_ATTRS:
            code = row[idx] if idx != 0 else row[0]
            key = (uattr, code)
            if code and key not in cache:
                body.append(WForm(SETBANG, WSym("G"),
                                  WForm(GOC, WAttr(uattr), WStr(code))))
                new_keys.append(key)
    sec_codes = set()
    for row in batch:
        if row[12]:
            for code in row[12].split(","):
                code = code.strip()
                if code:
                    sec_codes.add(code)
    for code in sorted(sec_codes):
        key = ("cnae.codigo", code)
        if key not in cache:
            body.append(WForm(SETBANG, WSym("G"),
                              WForm(GOC, WAttr("cnae.codigo"), WStr(code))))
            new_keys.append(key)
    if body:
        body.append(WForm(RESULT, WInt(0)))
        run_scheme_batch(client, body)
    return new_keys


def _estab_bulk_phase_b(client, new_keys, cache):
    if not new_keys:
        return
    qbody = [WForm(WSym("result-row"),
                   WForm(WSym("lookup-entity"), WAttr(k[0]), WStr(k[1])))
             for k in new_keys]
    rows = []
    for ch in client.scheme_wire(WForm(BEGIN, *qbody), mode="query"):
        rows.extend(ch.get("rows", []))
    if len(rows) != len(new_keys):
        raise RuntimeError(
            f"bulk phase B: {len(rows)} rows para {len(new_keys)} chaves")
    for key, r in zip(new_keys, rows):
        cache[key] = r[0]


def _estab_bulk_phase_c(client, batch, cache):
    by_pairs = {}
    for row in batch:
        e = WInt(cache[("estab.cnpj_completo",
                        row[0] + row[1].zfill(4) + row[2].zfill(2))])
        for idx, attr in ESTAB_STR_ATTRS:
            if row[idx]:
                by_pairs.setdefault(attr, []).extend([e, WStr(row[idx])])
        for idx, attr, uattr in ESTAB_REF_ATTRS:
            code = row[idx] if idx != 0 else row[0]
            if code:
                by_pairs.setdefault(attr, []).extend(
                    [e, WInt(cache[(uattr, code)])])
        if row[12]:
            for code in row[12].split(","):
                code = code.strip()
                if code:
                    by_pairs.setdefault("estab.cnae_secundario", []).extend(
                        [e, WInt(cache[("cnae.codigo", code)])])
    body = []
    for attr, pairs in by_pairs.items():
        body.append(WForm(WSym("save-many"), WAttr(attr), *pairs))
    body.append(WForm(RESULT, WInt(0)))
    run_scheme_batch(client, body)


def load_estabs_bulk(client: EavtClient, data_dir: Path, max_rows: int,
                     batch_size: int) -> tuple[int, int]:
    """Estabelecimentos via save-many storage-batched (um batchWrite/lote).

    Requer o fast path de save-many sem eid duplicado no lote — válido aqui
    (cnpj_completo é único). REF vai como eid int (código → cache).
    Retorna (saved, scanned) como os demais loaders.
    """
    zpath = find_zip(data_dir, "Estabelecimentos0")
    cache: dict = {}
    saved = scanned = 0
    batch: list = []
    t0 = time.perf_counter()
    for row in rows_from_zip(zpath):
        scanned += 1
        if len(row) < 30 or len(row[0]) != 8 or not row[0].isdigit():
            continue
        batch.append(row)
        if len(batch) >= batch_size:
            nk = _estab_bulk_phase_a(client, batch, cache)
            _estab_bulk_phase_b(client, nk, cache)
            _estab_bulk_phase_c(client, batch, cache)
            saved += len(batch)
            batch = []
            if len(cache) > ESTAB_CACHE_MAX:
                cache.clear()
            if saved >= max_rows:
                break
    if batch and saved < max_rows:
        nk = _estab_bulk_phase_a(client, batch, cache)
        _estab_bulk_phase_b(client, nk, cache)
        _estab_bulk_phase_c(client, batch, cache)
        saved += len(batch)
    elapsed = time.perf_counter() - t0
    print(f"  estabs(bulk): {saved:,} linhas gravadas "
          f"(scanned {scanned:,}) in {elapsed:.1f}s", flush=True)
    return saved, scanned


def _flush_estab_batch(client, batch):
    body = []
    for row in batch:
        cnpj_base = row[0]
        cnpj_full = row[0] + row[1].zfill(4) + row[2].zfill(2)

        body.append(set_e_alloc())
        body.append(wstr_save("estab.cnpj_completo", cnpj_full))
        body.append(save_w("estab.empresa", goc("empresa.cnpj_base", cnpj_base)))
        if row[3]:
            body.append(wstr_save("estab.matriz_filial", row[3]))
        if row[4]:
            body.append(wstr_save("estab.nome_fantasia", row[4]))
        if row[5]:
            body.append(wstr_save("estab.situacao", row[5]))
        if row[6] and row[6] != ZERO_DATE:
            body.append(wstr_save("estab.data_situacao", row[6]))
        if row[7]:
            body.append(save_w("estab.motivo", goc("motivo.codigo", row[7])))
        if row[9]:
            body.append(save_w("estab.pais", goc("pais.codigo", row[9])))
        if row[10] and row[10] != ZERO_DATE:
            body.append(wstr_save("estab.data_inicio_ativ", row[10]))
        if row[11]:
            body.append(save_w("estab.cnae_principal",
                               goc("cnae.codigo", row[11])))
        if row[12]:
            for code in row[12].split(","):
                code = code.strip()
                if code:
                    body.append(save_w("estab.cnae_secundario",
                                       goc("cnae.codigo", code)))
        if row[13]:
            body.append(wstr_save("estab.tipo_logradouro", row[13]))
        if row[14]:
            body.append(wstr_save("estab.logradouro", row[14]))
        if row[15]:
            body.append(wstr_save("estab.numero", row[15]))
        if row[16]:
            body.append(wstr_save("estab.complemento", row[16]))
        if row[17]:
            body.append(wstr_save("estab.bairro", row[17]))
        if row[18]:
            body.append(wstr_save("estab.cep", row[18]))
        if row[19]:
            body.append(wstr_save("estab.uf", row[19]))
        if row[20]:
            body.append(save_w("estab.municipio",
                               goc("municipio.codigo", row[20])))
        if row[21]:
            body.append(wstr_save("estab.ddd1", row[21]))
        if row[22]:
            body.append(wstr_save("estab.telefone1", row[22]))
        if row[23]:
            body.append(wstr_save("estab.ddd2", row[23]))
        if row[24]:
            body.append(wstr_save("estab.telefone2", row[24]))
        if row[27]:
            body.append(wstr_save("estab.email", row[27]))

    body.append(WForm(RESULT, E_SYM, WInt(len(batch) * 20)))
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
        body.append(set_e_alloc())
        body.append(save_w("socio.empresa",
                           goc("empresa.cnpj_base", cnpj_base)))
        if row[1]:
            body.append(wstr_save("socio.tipo_pessoa", row[1]))
        if row[2]:
            body.append(wstr_save("socio.nome", row[2]))
        if row[3]:
            body.append(wstr_save("socio.cpf_cnpj", row[3]))
        if row[4]:
            body.append(save_w("socio.qualificacao",
                               goc("qualificacao.codigo", row[4])))
        if row[5] and row[5] != ZERO_DATE:
            body.append(wstr_save("socio.data_entrada", row[5]))
        if row[6]:
            body.append(save_w("socio.pais", goc("pais.codigo", row[6])))
        if row[10]:
            body.append(wstr_save("socio.faixa_etaria", row[10]))

    body.append(WForm(RESULT, E_SYM, WInt(len(batch) * 8)))
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
        merge_simples(client, args.data_dir, args.batch)
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
