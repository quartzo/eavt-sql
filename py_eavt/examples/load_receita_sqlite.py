#!/usr/bin/env python3
"""load_receita_sqlite.py — Load Receita Federal CNPJ data into SQLite.

Relational reimplementation of load_receita.py with the same open-data files,
phase order and get-or-create semantics, but written to plain SQLite.

Data model (decided with the operator):
  - CNPJ (raiz/ordem/dv) is TEXT and alphanumeric-safe — no digit restriction,
    only length checks (raiz 8, ordem 4, dv 2). Receita will start emitting
    alphanumeric CNPJs (Aug 2026), so int()/isdigit() are forbidden here.
  - cnae is TEXT only: its code carries a significant leading zero
    ('0111301') and canonical notation uses punctuation ('0111-3/01').
  - The other reference tables (municipio, natureza, qualificacao, pais,
    motivo) are normalized to integer `id = int(codigo)` with the original
    `codigo` kept alongside (display/forensics). int() also resolves the
    padding quirk in `pais` ('23' vs '023') automatically.
  - Broken reference codes (e.g. `pais` '359'/'150'/'367' absent from the
    lookup) stay broken: the REF column holds the integer value anyway,
    dangling. Never NULL for a non-empty code, never a fabricated stub.

Usage:
    uv run python py_eavt/examples/load_receita_sqlite.py --n 5000
    uv run python py_eavt/examples/load_receita_sqlite.py --n 2000 \
        --max-simples 2000 --max-estabs 2000 --max-socios 2000
    uv run python py_eavt/examples/load_receita_sqlite.py --demo-only

Source: /home/fabio/dev/dagster_flows/tests_data/receita_zip
        (latin-1, ';'-separated, all fields quoted, no header)
"""
from __future__ import annotations

import argparse
import csv
import io
import sqlite3
import sys
import time
import zipfile
from pathlib import Path

DEFAULT_DATA = Path("/home/fabio/dev/dagster_flows/tests_data/receita_zip")
DEFAULT_DB = "/tmp/opencode/receita_sqlite.db"
SIMPLES_ZIP = "Simples__20260809T1834.zip"
ZERO_DATE = "00000000"
BATCH_ROWS = 50_000


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


def _s(v):
    """Empty string → NULL (mirrors EAVT 'don't save empty')."""
    return v if v else None


def _ref(v):
    """Reference code → integer. Empty → NULL; non-numeric non-empty raises
    (fail-stop: a broken code must not be silently dropped)."""
    return int(v) if v else None


# ═══════════════════════════════════════════════════════════════════════════════
# Schema
# ═══════════════════════════════════════════════════════════════════════════════

LOOKUPS = [
    ("Cnaes", "cnae", "descricao"),          # string-only (leading zero)
    ("Municipios", "municipio", "nome"),
    ("Naturezas", "natureza", "descricao"),
    ("Qualificacoes", "qualificacao", "descricao"),
    ("Paises", "pais", "nome"),
    ("Motivos", "motivo", "descricao"),
]

DDL = [
    "CREATE TABLE IF NOT EXISTS cnae(codigo TEXT PRIMARY KEY, descricao TEXT)",
    "CREATE TABLE IF NOT EXISTS municipio(id INTEGER PRIMARY KEY, codigo TEXT UNIQUE, nome TEXT)",
    "CREATE TABLE IF NOT EXISTS natureza(id INTEGER PRIMARY KEY, codigo TEXT UNIQUE, descricao TEXT)",
    "CREATE TABLE IF NOT EXISTS qualificacao(id INTEGER PRIMARY KEY, codigo TEXT UNIQUE, descricao TEXT)",
    "CREATE TABLE IF NOT EXISTS pais(id INTEGER PRIMARY KEY, codigo TEXT UNIQUE, nome TEXT)",
    "CREATE TABLE IF NOT EXISTS motivo(id INTEGER PRIMARY KEY, codigo TEXT UNIQUE, descricao TEXT)",
    "CREATE TABLE IF NOT EXISTS empresa("
    " cnpj_base TEXT PRIMARY KEY,"
    " razao_social TEXT,"
    " natureza_juridica_id INTEGER,"
    " qualificacao_resp_id INTEGER,"
    " capital_social REAL,"
    " porte TEXT,"
    " optante_simples TEXT,"
    " data_opcao_simples TEXT,"
    " data_exclusao_simples TEXT,"
    " optante_mei TEXT,"
    " data_opcao_mei TEXT,"
    " data_exclusao_mei TEXT)",
    "CREATE TABLE IF NOT EXISTS estabelecimento("
    " cnpj_completo TEXT PRIMARY KEY,"
    " cnpj_base TEXT NOT NULL,"
    " matriz_filial TEXT,"
    " nome_fantasia TEXT,"
    " situacao TEXT,"
    " data_situacao TEXT,"
    " motivo_id INTEGER,"
    " pais_id INTEGER,"
    " data_inicio_ativ TEXT,"
    " cnae_principal TEXT,"
    " tipo_logradouro TEXT,"
    " logradouro TEXT,"
    " numero TEXT,"
    " complemento TEXT,"
    " bairro TEXT,"
    " cep TEXT,"
    " uf TEXT,"
    " municipio_id INTEGER,"
    " ddd1 TEXT,"
    " telefone1 TEXT,"
    " ddd2 TEXT,"
    " telefone2 TEXT,"
    " email TEXT)",
    "CREATE TABLE IF NOT EXISTS estab_cnae_sec("
    " cnpj_completo TEXT NOT NULL,"
    " cnae TEXT NOT NULL,"
    " PRIMARY KEY(cnpj_completo, cnae))",
    "CREATE TABLE IF NOT EXISTS socio("
    " id INTEGER PRIMARY KEY,"
    " cnpj_base TEXT NOT NULL,"
    " tipo_pessoa TEXT,"
    " nome TEXT,"
    " cpf_cnpj TEXT,"
    " qualificacao_id INTEGER,"
    " data_entrada TEXT,"
    " pais_id INTEGER,"
    " faixa_etaria TEXT)",
]

INDEX_DDL = [
    "CREATE INDEX IF NOT EXISTS ix_estab_empresa ON estabelecimento(cnpj_base)",
    "CREATE INDEX IF NOT EXISTS ix_socio_empresa ON socio(cnpj_base)",
]

EMP_INSERT = (
    "INSERT INTO empresa(cnpj_base, razao_social, natureza_juridica_id,"
    " qualificacao_resp_id, capital_social, porte) VALUES (?,?,?,?,?,?)"
)
EMP_STUB = "INSERT OR IGNORE INTO empresa(cnpj_base) VALUES (?)"
SIMPLE_UPSERT = (
    "INSERT INTO empresa(cnpj_base, optante_simples, data_opcao_simples,"
    " data_exclusao_simples, optante_mei, data_opcao_mei, data_exclusao_mei)"
    " VALUES (?,?,?,?,?,?,?)"
    " ON CONFLICT(cnpj_base) DO UPDATE SET"
    " optante_simples = COALESCE(excluded.optante_simples, empresa.optante_simples),"
    " data_opcao_simples = COALESCE(excluded.data_opcao_simples, empresa.data_opcao_simples),"
    " data_exclusao_simples = COALESCE(excluded.data_exclusao_simples, empresa.data_exclusao_simples),"
    " optante_mei = COALESCE(excluded.optante_mei, empresa.optante_mei),"
    " data_opcao_mei = COALESCE(excluded.data_opcao_mei, empresa.data_opcao_mei),"
    " data_exclusao_mei = COALESCE(excluded.data_exclusao_mei, empresa.data_exclusao_mei)"
)
ESTAB_INSERT = (
    "INSERT INTO estabelecimento(cnpj_completo, cnpj_base, matriz_filial,"
    " nome_fantasia, situacao, data_situacao, motivo_id, pais_id, data_inicio_ativ,"
    " cnae_principal, tipo_logradouro, logradouro, numero, complemento, bairro,"
    " cep, uf, municipio_id, ddd1, telefone1, ddd2, telefone2, email)"
    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
)
CNAE_SEC_INSERT = (
    "INSERT OR IGNORE INTO estab_cnae_sec(cnpj_completo, cnae) VALUES (?,?)"
)
SOCIO_INSERT = (
    "INSERT INTO socio(cnpj_base, tipo_pessoa, nome, cpf_cnpj, qualificacao_id,"
    " data_entrada, pais_id, faixa_etaria) VALUES (?,?,?,?,?,?,?,?)"
)


def open_db(path: str, load: bool = True) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA foreign_keys = OFF")
    conn.execute("PRAGMA temp_store = MEMORY")
    conn.execute("PRAGMA cache_size = -524288")
    conn.execute("PRAGMA synchronous = OFF" if load else "PRAGMA synchronous = NORMAL")
    return conn


def create_schema(conn: sqlite3.Connection):
    for stmt in DDL:
        conn.execute(stmt)
    conn.commit()


def create_indexes(conn: sqlite3.Connection):
    for stmt in INDEX_DDL:
        conn.execute(stmt)
    conn.commit()


def _chunk(rows_iter, size=BATCH_ROWS):
    buf = []
    for r in rows_iter:
        buf.append(r)
        if len(buf) >= size:
            yield buf
            buf = []
    if buf:
        yield buf


# ═══════════════════════════════════════════════════════════════════════════════
# Loaders
# ═══════════════════════════════════════════════════════════════════════════════

def load_lookups(conn: sqlite3.Connection, data_dir: Path) -> dict[str, int]:
    counts = {}
    for zip_prefix, table, desc_col in LOOKUPS:
        zpath = find_zip(data_dir, zip_prefix)
        if table == "cnae":
            rows = [(row[0], row[1]) for row in rows_from_zip(zpath)
                    if len(row) >= 2 and row[0]]
            conn.executemany(
                f"INSERT OR IGNORE INTO cnae(codigo, {desc_col}) VALUES (?,?)", rows)
        else:
            rows = [(int(row[0]), row[0], row[1]) for row in rows_from_zip(zpath)
                    if len(row) >= 2 and row[0]]
            conn.executemany(
                f"INSERT OR IGNORE INTO {table}(id, codigo, {desc_col})"
                " VALUES (?,?,?)", rows)
        conn.commit()
        counts[table] = len(rows)
        print(f"  {table}: {len(rows):,} entries", flush=True)
    return counts


def load_empresas(conn: sqlite3.Connection, data_dir: Path, n: int) -> int:
    zpath = find_zip(data_dir, "Empresas0")

    def gen():
        count = 0
        for row in rows_from_zip(zpath):
            if count >= n:
                return
            if len(row) < 6:
                continue
            cnpj = row[0]
            if len(cnpj) != 8:
                continue
            count += 1
            capital = None
            if row[4]:
                capital = float(row[4].replace(",", "."))
            yield (cnpj, _s(row[1]), _ref(row[2]), _ref(row[3]),
                   capital, _s(row[5]))

    total = 0
    for chunk in _chunk(gen()):
        conn.executemany(EMP_INSERT, chunk)
        total += len(chunk)
        conn.commit()
    print(f"  empresas: {total:,}", flush=True)
    return total


def merge_simples(conn: sqlite3.Connection, data_dir: Path,
                  max_rows: int = 0) -> int:
    zpath = data_dir / SIMPLES_ZIP

    def gen():
        processed = 0
        for row in rows_from_zip(zpath):
            if len(row) < 7:
                continue
            if max_rows and processed >= max_rows:
                return

            def d(i):
                v = row[i]
                return _s(v) if v and v != ZERO_DATE else None
            yield (row[0], _s(row[1]), d(2), d(3), _s(row[4]), d(5), d(6))
            processed += 1

    total = 0
    for chunk in _chunk(gen()):
        conn.executemany(SIMPLE_UPSERT, chunk)
        total += len(chunk)
        conn.commit()
    print(f"  simples: {total:,} linhas", flush=True)
    return total


def load_estabs(conn: sqlite3.Connection, data_dir: Path,
                max_rows: int = 0) -> tuple[int, int]:
    """Load estabs + secondary CNAEs (junction) in a single pass."""
    zpath = find_zip(data_dir, "Estabelecimentos0")

    def gen():
        saved = 0
        for row in rows_from_zip(zpath):
            if len(row) < 30:
                continue
            base = row[0]
            if len(base) != 8:
                continue
            if max_rows and saved >= max_rows:
                return
            cnpj_full = base + row[1].zfill(4) + row[2].zfill(2)

            def d(i):
                v = row[i]
                return _s(v) if v and v != ZERO_DATE else None

            sec = [c.strip() for c in row[12].split(",") if c.strip()]
            estab = (cnpj_full, base, _s(row[3]), _s(row[4]), _s(row[5]), d(6),
                     _ref(row[7]), _ref(row[9]), d(10), _s(row[11]), _s(row[13]),
                     _s(row[14]), _s(row[15]), _s(row[16]), _s(row[17]),
                     _s(row[18]), _s(row[19]), _ref(row[20]), _s(row[21]),
                     _s(row[22]), _s(row[23]), _s(row[24]), _s(row[27]))
            yield (estab, sec)
            saved += 1

    total = sec_total = 0
    for chunk in _chunk(gen()):
        conn.executemany(EMP_STUB, [(r[0][1],) for r in chunk])
        conn.executemany(ESTAB_INSERT, [r[0] for r in chunk])
        sec_rows = [(r[0][0], code) for r in chunk for code in r[1]]
        if sec_rows:
            conn.executemany(CNAE_SEC_INSERT, sec_rows)
        total += len(chunk)
        sec_total += len(sec_rows)
        conn.commit()
    print(f"  estabelecimentos: {total:,} (cnae_sec {sec_total:,})", flush=True)
    return total, sec_total


def load_socios(conn: sqlite3.Connection, data_dir: Path,
                max_rows: int = 0) -> int:
    zpath = find_zip(data_dir, "Socios0")

    def gen():
        saved = 0
        for row in rows_from_zip(zpath):
            if len(row) < 11:
                continue
            base = row[0]
            if len(base) != 8:
                continue
            if max_rows and saved >= max_rows:
                return

            def d(i):
                v = row[i]
                return _s(v) if v and v != ZERO_DATE else None
            yield (base, _s(row[1]), _s(row[2]), _s(row[3]), _ref(row[4]),
                   d(5), _ref(row[6]), _s(row[10]))
            saved += 1

    total = 0
    for chunk in _chunk(gen()):
        conn.executemany(EMP_STUB, [(r[0],) for r in chunk])
        conn.executemany(SOCIO_INSERT, chunk)
        total += len(chunk)
        conn.commit()
    print(f"  socios: {total:,}", flush=True)
    return total


# ═══════════════════════════════════════════════════════════════════════════════
# Demo queries
# ═══════════════════════════════════════════════════════════════════════════════

def demo(conn: sqlite3.Connection):
    print("\n=== Demo queries ===")

    row = conn.execute(
        "SELECT cnpj_base, razao_social FROM empresa LIMIT 1").fetchone()
    if row is None:
        print("  (empty DB)")
        return
    cnpj, rs = row
    print(f"first empresa: cnpj={cnpj} rs={rs[:40]!r}")

    t0 = time.perf_counter()
    r = conn.execute(
        "SELECT razao_social FROM empresa WHERE cnpj_base = ?", (cnpj,)).fetchone()
    print(f"lookup_entity → {r[0][:40]!r}  "
          f"({(time.perf_counter() - t0) * 1000:.2f}ms)")

    t0 = time.perf_counter()
    rows = conn.execute(
        "SELECT cnpj_completo, nome_fantasia, situacao FROM estabelecimento"
        " WHERE cnpj_base = ? LIMIT 5", (cnpj,)).fetchall()
    print(f"estabs of empresa: {len(rows)} (limit 5)  "
          f"({(time.perf_counter() - t0) * 1000:.2f}ms)")
    for r in rows:
        print(f"    {r[0]}  sit={r[2]}  {str(r[1])[:40]!r}")

    t0 = time.perf_counter()
    rows = conn.execute(
        "SELECT nome FROM socio WHERE cnpj_base = ? LIMIT 5", (cnpj,)).fetchall()
    print(f"socios: {len(rows)} (limit 5)  "
          f"({(time.perf_counter() - t0) * 1000:.2f}ms)")
    for r in rows:
        print(f"    {str(r[0])[:50]!r}")

    t0 = time.perf_counter()
    rows = conn.execute(
        "SELECT razao_social, capital_social FROM empresa"
        " WHERE capital_social >= ? LIMIT 5", (1000.0,)).fetchall()
    print(f"capital >= 1.000: {len(rows)} (limit 5)  "
          f"({(time.perf_counter() - t0) * 1000:.2f}ms)")
    for r in rows:
        print(f"    {str(r[0])[:40]!r}  capital={r[1]:,.2f}")

    t0 = time.perf_counter()
    rows = conn.execute(
        "SELECT e.cnpj_completo, e.pais_id, p.nome FROM estabelecimento e"
        " LEFT JOIN pais p ON e.pais_id = p.id LIMIT 5").fetchall()
    print(f"estabs → pais (LEFT JOIN):  "
          f"({(time.perf_counter() - t0) * 1000:.2f}ms)")
    for r in rows:
        print(f"    {r[0]}  pais_id={r[1]}  nome={r[2]!r}")


# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    ap = argparse.ArgumentParser(description="Load Receita CNPJ data into SQLite")
    ap.add_argument("--n", type=int, default=1_000_000,
                    help="number of empresas to load (default 1M)")
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
    ap.add_argument("--demo-only", action="store_true",
                    help="skip loading, run demo queries on existing DB")
    ap.add_argument("--max-simples", type=int, default=0,
                    help="max simples rows to process (0=all)")
    ap.add_argument("--max-estabs", type=int, default=0,
                    help="max estabelecimentos to process (0=all)")
    ap.add_argument("--max-socios", type=int, default=0,
                    help="max socios to process (0=all)")
    args = ap.parse_args()

    if args.demo_only:
        conn = open_db(args.db, load=False)
        demo(conn)
        conn.close()
        return 0

    if Path(args.db).exists():
        print(f"DB at {args.db} already exists — use a fresh --db or --demo-only")
        return 1

    conn = open_db(args.db)
    create_schema(conn)

    print(f"== Lookups (data: {args.data_dir}) ==", flush=True)
    load_lookups(conn, args.data_dir)

    print(f"== Empresas0 (first {args.n:,}) ==", flush=True)
    load_empresas(conn, args.data_dir, args.n)

    print("== Simples (merge into empresas) ==", flush=True)
    merge_simples(conn, args.data_dir, args.max_simples)

    print("== Estabelecimentos0 ==", flush=True)
    load_estabs(conn, args.data_dir, args.max_estabs)

    print("== Socios0 ==", flush=True)
    load_socios(conn, args.data_dir, args.max_socios)

    print("== Índices secundários ==", flush=True)
    create_indexes(conn)

    demo(conn)
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
