#!/usr/bin/env python3
"""load_receita.py — Load Receita Federal CNPJ open data into py_eavt.

Loads all lookup tables (CNAE, municípios, naturezas, qualificações,
países, motivos), then group 0 of Empresas (first --n), Estabelecimentos
(filtered to loaded empresas), Socios (filtered), and Simples (merged
into empresas as extra attributes).

Usage:
    cd py_eavt
    uv run python examples/load_receita.py --n 5000    # quick test
    uv run python examples/load_receita.py              # full 1M empresas
    uv run python examples/load_receita.py --demo-only  # queries on loaded DB

Source: /home/fabiro/dev/dagster_flows/tests_data/receita_zip
        (latin-1, ';'-separated, all fields quoted, no header)
DB:     /tmp/opencode/receita_eavt (created fresh; aborts if already loaded)

Field layouts (verified empirically):
    Empresas      7 cols: cnpj_base razao_social natureza qualif capital porte ente
    Estabele     30 cols: base ordem dv matriz fantasia situacao data_sit motivo
                       cidade_ext pais data_inicio cnae_f cnae_sec tipo_logr logr
                       num compl bairro cep uf municipio ddd1 tel1 ddd2 tel2
                       ddd_fax fax email sit_esp data_sit_esp
    Socios       11 cols: base tipo nome cpf qualif data_entrada pais
                       cpf_rep nome_rep qualif_rep faixa
    Simples       7 cols: base op_simples dt_op_s dt_exc_s op_mei dt_op_mei dt_exc_mei
    Lookups        2 cols: codigo descricao/nome
"""
from __future__ import annotations

import argparse
import csv
import io
import sys
import time
import zipfile
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_root / "src"))

from eavt import EavtEngine, QuerySession, prepare  # noqa: E402

DEFAULT_DATA = Path("/home/fabio/dev/dagster_flows/tests_data/receita_zip")
DEFAULT_DB = "/tmp/opencode/receita_eavt"
COMMIT_EVERY = 200_000
ZERO_DATE = "00000000"


def rows_from_zip(zip_path: Path):
    """Stream rows from the single CSV inside a receita zip (latin-1, ';')."""
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


class Loader:
    """Save wrapper with periodic commit + per-phase progress reporting."""

    def __init__(self, sess: QuerySession):
        self.sess = sess
        self.saves = 0
        self._next_commit = COMMIT_EVERY
        self.phase_saves = 0
        self.phase_t0 = time.perf_counter()

    def mark(self):
        """Reset phase counters (call at the start of each load phase)."""
        self.phase_saves = 0
        self.phase_t0 = time.perf_counter()

    def save(self, eid: int, attr: str, val):
        self.sess.save(eid, attr, val)
        self.saves += 1
        self.phase_saves += 1
        if self.saves >= self._next_commit:
            self.sess.commit()
            self._next_commit = self.saves + COMMIT_EVERY
            elapsed = time.perf_counter() - self.phase_t0
            print(f"    {self.phase_saves:>10,} datoms  {elapsed:7.1f}s  "
                  f"({self.phase_saves / elapsed:,.0f}/s)", flush=True)

    def finish(self):
        self.sess.commit()
        elapsed = time.perf_counter() - self.phase_t0
        if self.phase_saves:
            print(f"    phase total {self.phase_saves:,} datoms in {elapsed:.1f}s "
                  f"({self.phase_saves / elapsed:,.0f}/s)", flush=True)


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


def declare_schema(sess: QuerySession):
    for _, prefix, desc_attr in LOOKUPS:
        sess.declare_attr(f"{prefix}.codigo", "string", unique=True)
        sess.declare_attr(f"{prefix}.{desc_attr}", "string")

    sess.declare_attr("empresa.cnpj_base", "string", unique=True)
    sess.declare_attr("empresa.razao_social", "string")
    sess.declare_attr("empresa.natureza_juridica", "ref")
    sess.declare_attr("empresa.qualificacao_resp", "ref")
    sess.declare_attr("empresa.capital_social", "float")
    sess.declare_attr("empresa.porte", "string")
    sess.declare_attr("empresa.optante_simples", "string")
    sess.declare_attr("empresa.data_opcao_simples", "string")
    sess.declare_attr("empresa.data_exclusao_simples", "string")
    sess.declare_attr("empresa.optante_mei", "string")
    sess.declare_attr("empresa.data_opcao_mei", "string")
    sess.declare_attr("empresa.data_exclusao_mei", "string")

    sess.declare_attr("estab.cnpj_completo", "string", unique=True)
    sess.declare_attr("estab.empresa", "ref")
    sess.declare_attr("estab.matriz_filial", "string")
    sess.declare_attr("estab.nome_fantasia", "string")
    sess.declare_attr("estab.situacao", "string")
    sess.declare_attr("estab.data_situacao", "string")
    sess.declare_attr("estab.motivo", "ref")
    sess.declare_attr("estab.pais", "ref")
    sess.declare_attr("estab.data_inicio_ativ", "string")
    sess.declare_attr("estab.cnae_principal", "ref")
    sess.declare_attr("estab.cnae_secundario", "ref", many=True)
    sess.declare_attr("estab.tipo_logradouro", "string")
    sess.declare_attr("estab.logradouro", "string")
    sess.declare_attr("estab.numero", "string")
    sess.declare_attr("estab.complemento", "string")
    sess.declare_attr("estab.bairro", "string")
    sess.declare_attr("estab.cep", "string")
    sess.declare_attr("estab.uf", "string")
    sess.declare_attr("estab.municipio", "ref")
    sess.declare_attr("estab.ddd1", "string")
    sess.declare_attr("estab.telefone1", "string")
    sess.declare_attr("estab.ddd2", "string")
    sess.declare_attr("estab.telefone2", "string")
    sess.declare_attr("estab.email", "string")

    sess.declare_attr("socio.empresa", "ref")
    sess.declare_attr("socio.tipo_pessoa", "string")
    sess.declare_attr("socio.nome", "string")
    sess.declare_attr("socio.cpf_cnpj", "string")
    sess.declare_attr("socio.qualificacao", "ref")
    sess.declare_attr("socio.data_entrada", "string")
    sess.declare_attr("socio.pais", "ref")
    sess.declare_attr("socio.faixa_etaria", "string")


# ═══════════════════════════════════════════════════════════════════════════════
# Loaders
# ═══════════════════════════════════════════════════════════════════════════════

def load_lookups(sess, ld, data_dir):
    """Load all lookup tables. Returns {table: {codigo: eid}}."""
    maps = {}
    for zip_prefix, prefix, desc_attr in LOOKUPS:
        zpath = find_zip(data_dir, zip_prefix)
        codes = {}
        for row in rows_from_zip(zpath):
            if len(row) < 2 or not row[0]:
                continue
            eid = sess.alloc_entity()
            ld.save(eid, f"{prefix}.codigo", row[0])
            ld.save(eid, f"{prefix}.{desc_attr}", row[1])
            codes[row[0]] = eid
        maps[prefix] = codes
        print(f"  {prefix}: {len(codes):,} entries", flush=True)
    ld.finish()
    return maps


def load_empresas(sess, ld, data_dir, maps, n):
    """Load first n empresas from Empresas0. Returns {cnpj_base: eid}."""
    zpath = find_zip(data_dir, "Empresas0")
    nat = maps["natureza"]
    qual = maps["qualificacao"]
    by_cnpj = {}
    for row in rows_from_zip(zpath):
        if len(row) < 6:
            continue
        cnpj = row[0]
        if len(cnpj) != 8 or not cnpj.isdigit():
            continue
        eid = sess.alloc_entity()
        ld.save(eid, "empresa.cnpj_base", cnpj)
        if row[1]:
            ld.save(eid, "empresa.razao_social", row[1])
        if row[2]:
            e = nat.get(row[2])
            if e is not None:
                ld.save(eid, "empresa.natureza_juridica", e)
        if row[3]:
            e = qual.get(row[3])
            if e is not None:
                ld.save(eid, "empresa.qualificacao_resp", e)
        if row[4]:
            ld.save(eid, "empresa.capital_social", float(row[4].replace(",", ".")))
        if row[5]:
            ld.save(eid, "empresa.porte", row[5])
        by_cnpj[cnpj] = eid
        if len(by_cnpj) >= n:
            break
    ld.finish()
    print(f"  empresas: {len(by_cnpj):,}", flush=True)
    return by_cnpj


def merge_simples(sess, ld, data_dir, by_cnpj):
    """Stream Simples, merge optação into already-loaded empresas."""
    zpath = data_dir / "Simples__20260809T1834.zip"
    matched = 0
    for row in rows_from_zip(zpath):
        if len(row) < 7:
            continue
        eid = by_cnpj.get(row[0])
        if eid is None:
            continue
        if row[1]:
            ld.save(eid, "empresa.optante_simples", row[1])
        if row[2] and row[2] != ZERO_DATE:
            ld.save(eid, "empresa.data_opcao_simples", row[2])
        if row[3] and row[3] != ZERO_DATE:
            ld.save(eid, "empresa.data_exclusao_simples", row[3])
        if row[4]:
            ld.save(eid, "empresa.optante_mei", row[4])
        if row[5] and row[5] != ZERO_DATE:
            ld.save(eid, "empresa.data_opcao_mei", row[5])
        if row[6] and row[6] != ZERO_DATE:
            ld.save(eid, "empresa.data_exclusao_mei", row[6])
        matched += 1
    ld.finish()
    print(f"  simples matched: {matched:,}", flush=True)


def load_estabs(sess, ld, data_dir, by_cnpj, maps):
    """Stream Estabelecimentos0, save only estabs of loaded empresas."""
    zpath = find_zip(data_dir, "Estabelecimentos0")
    mot = maps["motivo"]
    pais = maps["pais"]
    cnae = maps["cnae"]
    mun = maps["municipio"]

    count = 0
    scanned = 0
    for row in rows_from_zip(zpath):
        scanned += 1
        if scanned % 5_000_000 == 0:
            print(f"    scanned {scanned:,} rows, saved {count:,} estabs", flush=True)
        if len(row) < 30:
            continue
        emp_eid = by_cnpj.get(row[0])
        if emp_eid is None:
            continue
        cnpj_full = row[0] + row[1].zfill(4) + row[2].zfill(2)
        eid = sess.alloc_entity()
        ld.save(eid, "estab.cnpj_completo", cnpj_full)
        ld.save(eid, "estab.empresa", emp_eid)
        if row[3]:
            ld.save(eid, "estab.matriz_filial", row[3])
        if row[4]:
            ld.save(eid, "estab.nome_fantasia", row[4])
        if row[5]:
            ld.save(eid, "estab.situacao", row[5])
        if row[6] and row[6] != ZERO_DATE:
            ld.save(eid, "estab.data_situacao", row[6])
        if row[7]:
            e = mot.get(row[7])
            if e is not None:
                ld.save(eid, "estab.motivo", e)
        if row[9]:
            e = pais.get(row[9])
            if e is not None:
                ld.save(eid, "estab.pais", e)
        if row[10] and row[10] != ZERO_DATE:
            ld.save(eid, "estab.data_inicio_ativ", row[10])
        if row[11]:
            e = cnae.get(row[11])
            if e is not None:
                ld.save(eid, "estab.cnae_principal", e)
        if row[12]:
            for code in row[12].split(","):
                code = code.strip()
                if code:
                    e = cnae.get(code)
                    if e is not None:
                        ld.save(eid, "estab.cnae_secundario", e)
        if row[13]:
            ld.save(eid, "estab.tipo_logradouro", row[13])
        if row[14]:
            ld.save(eid, "estab.logradouro", row[14])
        if row[15]:
            ld.save(eid, "estab.numero", row[15])
        if row[16]:
            ld.save(eid, "estab.complemento", row[16])
        if row[17]:
            ld.save(eid, "estab.bairro", row[17])
        if row[18]:
            ld.save(eid, "estab.cep", row[18])
        if row[19]:
            ld.save(eid, "estab.uf", row[19])
        if row[20]:
            e = mun.get(row[20])
            if e is not None:
                ld.save(eid, "estab.municipio", e)
        if row[21]:
            ld.save(eid, "estab.ddd1", row[21])
        if row[22]:
            ld.save(eid, "estab.telefone1", row[22])
        if row[23]:
            ld.save(eid, "estab.ddd2", row[23])
        if row[24]:
            ld.save(eid, "estab.telefone2", row[24])
        if row[27]:
            ld.save(eid, "estab.email", row[27])
        count += 1
    ld.finish()
    print(f"  estabelecimentos: {count:,} (scanned {scanned:,})", flush=True)


def load_socios(sess, ld, data_dir, by_cnpj, maps):
    """Stream Socios0, save only socios of loaded empresas."""
    zpath = find_zip(data_dir, "Socios0")
    qual = maps["qualificacao"]
    pais = maps["pais"]
    count = 0
    for row in rows_from_zip(zpath):
        if len(row) < 11:
            continue
        emp_eid = by_cnpj.get(row[0])
        if emp_eid is None:
            continue
        eid = sess.alloc_entity()
        ld.save(eid, "socio.empresa", emp_eid)
        if row[1]:
            ld.save(eid, "socio.tipo_pessoa", row[1])
        if row[2]:
            ld.save(eid, "socio.nome", row[2])
        if row[3]:
            ld.save(eid, "socio.cpf_cnpj", row[3])
        if row[4]:
            e = qual.get(row[4])
            if e is not None:
                ld.save(eid, "socio.qualificacao", e)
        if row[5] and row[5] != ZERO_DATE:
            ld.save(eid, "socio.data_entrada", row[5])
        if row[6]:
            e = pais.get(row[6])
            if e is not None:
                ld.save(eid, "socio.pais", e)
        if row[10]:
            ld.save(eid, "socio.faixa_etaria", row[10])
        count += 1
    ld.finish()
    print(f"  socios: {count:,}", flush=True)


# ═══════════════════════════════════════════════════════════════════════════════
# Demo queries
# ═══════════════════════════════════════════════════════════════════════════════

def demo(eng: EavtEngine, sess: QuerySession):
    print("\n=== Demo queries ===")

    # 1. first() empresa — early termination (no full scan)
    q = prepare(sess, ["?e", "?c", "?rs"], [
        ("?e", "empresa.cnpj_base", "?c"),
        ("?e", "empresa.razao_social", "?rs"),
    ])
    t0 = time.perf_counter()
    row = q.first()
    if row is None:
        print("  (empty DB)")
        return
    print(f"first() empresa: cnpj={row[1]} rs={row[2][:40]!r}  "
          f"({(time.perf_counter() - t0) * 1000:.2f}ms)")

    # 2. lookup_entity by unique attr (point lookup)
    t0 = time.perf_counter()
    eid = eng.lookup_entity("empresa.cnpj_base", row[1])
    rs = eng.lookup_value(eid, "empresa.razao_social")
    print(f"lookup_entity → {rs[:40]!r}  ({(time.perf_counter() - t0) * 1000:.2f}ms)")

    # 3. Estabs: pick an empresa that HAS one (via first estab's ref)
    q_fe = prepare(sess, ["?est", "?cnpj", "?emp"], [
        ("?est", "estab.cnpj_completo", "?cnpj"),
        ("?est", "estab.empresa", "?emp"),
    ])
    fe = q_fe.first()
    if fe is None:
        print("  (no estabelecimentos in subset)")
    else:
        emp_eid = fe[2]
        t0 = time.perf_counter()
        q_est = prepare(sess, ["?e", "?cnpj"], [
            ("?e", "estab.empresa", emp_eid),
            ("?e", "estab.cnpj_completo", "?cnpj"),
        ])
        rows = q_est.collect(limit=5)
        print(f"estabs of empresa: {len(rows)} (limit 5)  "
              f"({(time.perf_counter() - t0) * 1000:.2f}ms incl. prepare)")
        for r in rows:
            fant = eng.lookup_value(r[0], "estab.nome_fantasia") or ""
            sit = eng.lookup_value(r[0], "estab.situacao") or ""
            print(f"    {r[1]}  sit={sit}  {str(fant)[:40]!r}")

        # 4. Socios of the same empresa
        t0 = time.perf_counter()
        q_soc = prepare(sess, ["?s", "?nome"], [
            ("?s", "socio.empresa", emp_eid),
            ("?s", "socio.nome", "?nome"),
        ])
        soc_rows = q_soc.collect(limit=5)
        print(f"socios: {len(soc_rows)} (limit 5)  "
              f"({(time.perf_counter() - t0) * 1000:.2f}ms)")
        for r in soc_rows:
            print(f"    {str(r[1])[:50]!r}")

    # 5. Range: capital >= 1000 (raw-bytes lexicographic comparison)
    t0 = time.perf_counter()
    q_cap = prepare(sess, ["?e", "?rs", "?cap"], [
        ("?e", "empresa.razao_social", "?rs"),
        ("?e", "empresa.capital_social", "?cap"),
    ], ranges={"?cap": (">=", 1_000.0)})
    cap_rows = q_cap.collect(limit=5)
    print(f"capital >= 1.000: {len(cap_rows)} (limit 5)  "
          f"({(time.perf_counter() - t0) * 1000:.2f}ms)")
    for r in cap_rows:
        print(f"    {str(r[1])[:40]!r}  capital={r[2]:,.2f}")


# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    ap = argparse.ArgumentParser(description="Load Receita CNPJ data into py_eavt")
    ap.add_argument("--n", type=int, default=1_000_000,
                    help="number of empresas to load (default 1M)")
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
    ap.add_argument("--demo-only", action="store_true",
                    help="skip loading, run demo queries on existing DB")
    args = ap.parse_args()

    eng = EavtEngine(args.db)
    eng.bootstrap()

    if args.demo_only:
        sess = QuerySession(eng)
        demo(eng, sess)
        eng.close()
        return 0

    if eng.lookup_attr("empresa.cnpj_base") is not None:
        print(f"DB at {args.db} already loaded — use a fresh --db or --demo-only")
        eng.close()
        return 1

    sess = QuerySession(eng)
    declare_schema(sess)
    sess.commit()
    ld = Loader(sess)

    print(f"== Lookups (data: {args.data_dir}) ==", flush=True)
    maps = load_lookups(sess, ld, args.data_dir)

    ld.mark()
    print(f"== Empresas0 (first {args.n:,}) ==", flush=True)
    by_cnpj = load_empresas(sess, ld, args.data_dir, maps, args.n)

    ld.mark()
    print("== Simples (merge into empresas) ==", flush=True)
    merge_simples(sess, ld, args.data_dir, by_cnpj)

    ld.mark()
    print("== Estabelecimentos0 (filtered) ==", flush=True)
    load_estabs(sess, ld, args.data_dir, by_cnpj, maps)

    ld.mark()
    print("== Socios0 (filtered) ==", flush=True)
    load_socios(sess, ld, args.data_dir, by_cnpj, maps)

    print(f"\nTotal datoms saved: {ld.saves:,}")
    demo(eng, sess)
    eng.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
