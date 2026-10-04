#!/usr/bin/env python3
"""bench_client_split.py — o throughput da carga é limitado pelo cliente Python?

Reproduz o pipeline EXATO do harness de referência
(`tests/bench_receita_hydrated.py`: serial, 1 batch em voo, mesmo protocolo,
mesmos builders de ops do `load_receita_edn`) e decompõe cada estágio:

  fases do cliente (somam `wall` quando depth=1)
    read    inflate do zip + decode CSV + filtro (só com --data-dir)
    build   montagem das ops (loops Python + RefTids)
    wire    to_wire() recursivo (Kw → ext 0x06)
    pack    msgpack.Packer.pack do batch inteiro
    send    sendall (4B hdr + payload)
    recv    BLOQUEADO esperando o servidor → é o round-trip do server
    unpack  msgpack.unpackb da resposta + overhead Python

  CPU real (% de 1 núcleo, sobre o wall do estágio)
    cliente  time.process_time()
    query    Δ(utime+stime) de /proc/<pid>/stat
    trans    idem

Leitura: qual fase domina o wall? Se `recv` domina → servidor (compute ou
serialização); se build+wire+pack dominam → cliente Python. Os tetos
`ideal-cliente`/`ideal-servidor` dizem quanto sobreria com o outro lado
instantâneo.

`--data-dir <dir>` lê os zips REAIS da Receita (ex.
`/home/ubuntu/dev/dagster_flows/tests_data/receita_zip`) e a fase `read` mede
inflate + decode CSV + filtro — o custo real de leitura do cliente. Sem a
flag, gera linhas sintéticas com o MESMO formato (pools de códigos
pré-carregados como no estágio `lookups`).
"""
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import time
from collections import deque
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_root / "py_eavt_client" / "src"))
sys.path.insert(0, str(_root / "py_eavt" / "examples"))

import msgpack  # noqa: E402

from eavt_client.client import EavtClient, Kw  # noqa: E402
import eavt_client.client as CC  # noqa: E402
import load_receita_edn as L  # noqa: E402

OUT_DIR = Path("/tmp/opencode/receita_bench")

# ── dados sintéticos (mesmo formato das linhas da Receita) ───────────────────

def make_pools() -> dict[str, list[str]]:
    rng = random.Random(7)
    pools = {
        "natureza": [f"{i:04d}" for i in range(1, 101)],
        "qualificacao": [f"{i:02d}" for i in range(1, 61)],
        "motivo": [f"{i:02d}" for i in range(1, 11)],
        "pais": ["105", "205", "310", "415", "520"],
        "cnae": [f"{i:07d}" for i in range(1_000_001, 1_000_501)],
        "municipio": [f"{i:07d}" for i in range(1_100_001, 1_101_001)],
    }
    assert all(len(v) > 0 for v in pools.values())
    rng.shuffle(pools["motivo"])
    return pools


LOOKUP_DESC = {
    "cnae": "descricao", "municipio": "nome", "motivo": "descricao",
    "pais": "nome", "natureza": "descricao", "qualificacao": "descricao",
}


def gen_lookup_rows(pools: dict[str, list[str]]) -> list[list]:
    """(prefix, attr_desc, codigo, descricao) — uma entidade por código,
    ancorada no próprio código único (como o load_lookups de referência)."""
    rows = []
    for prefix, codes in pools.items():
        desc_attr = LOOKUP_DESC[prefix]
        for code in codes:
            rows.append([prefix, desc_attr, code, f"{prefix} {code}"])
    return rows


def build_lookup_ops(rows: list) -> list:
    ops: list = []
    for i, (prefix, desc_attr, code, desc) in enumerate(rows):
        tid = -(i + 1)
        ops.append(L.op_add(tid, f"{prefix}/codigo", code))
        ops.append(L.op_add(tid, f"{prefix}/{desc_attr}", desc))
    return ops


def gen_empresas(n: int, pools, rng) -> list[list[str]]:
    rows = []
    for i in range(n):
        rows.append([
            f"{i:08d}",
            f"EMPRESA {i:08d} LTDA",
            rng.choice(pools["natureza"]),
            rng.choice(pools["qualificacao"]),
            f"{rng.randint(1_000, 999_999_999)},{rng.randint(0, 99):02d}",
            rng.choice(["01", "03", "05"]),
        ])
    return rows


def gen_estabs(n: int, n_empresas: int, pools, rng) -> list[list[str]]:
    rows = []
    for i in range(n):
        r = [""] * 30
        r[0] = f"{i % n_empresas:08d}"      # âncora empresa já existente
        r[1] = f"{rng.randint(1, 9999):04d}"
        r[2] = f"{rng.randint(0, 99):02d}"
        r[3] = rng.choice(["0", "1"])
        r[4] = f"FILIAL {i:06d}"
        r[5] = "02"
        r[6] = "20200101"
        r[7] = rng.choice(pools["motivo"])
        r[9] = rng.choice(pools["pais"])
        r[10] = "20150101"
        r[11] = rng.choice(pools["cnae"])
        r[12] = ",".join(rng.sample(pools["cnae"], 2))
        r[13] = "RUA"
        r[14] = "Rua das Flores"
        r[15] = str(rng.randint(1, 2000))
        r[17] = "Centro"
        r[18] = f"{rng.randint(1_000_000, 9_999_999)}"
        r[19] = "SP"
        r[20] = rng.choice(pools["municipio"])
        r[21] = "11"
        r[22] = f"{rng.randint(10_000_000, 99_999_999)}"
        r[27] = f"contato{i}@empresa.com.br"
        rows.append(r)
    return rows


def real_lookup_chunks(data_dir: Path, batch: int):
    """Estágio `load_lookups` do harness sobre os zips REAIS (streaming)."""
    rows: list = []
    for zip_prefix, prefix, desc_attr in L.LOOKUPS:
        for row in L.rows_from_zip(L.find_zip(data_dir, zip_prefix)):
            if len(row) < 2 or not row[0]:
                continue
            rows.append([prefix, desc_attr, row[0], row[1]])
            if len(rows) >= batch:
                yield rows
                rows = []
    if rows:
        yield rows


def real_empresas_chunks(data_dir: Path, batch: int, n: int):
    """Filtros de `load_empresas` (load_receita_edn.py:251) sobre Empresas0."""
    saved = 0
    rows: list = []
    for row in L.rows_from_zip(L.find_zip(data_dir, "Empresas0")):
        if len(row) < 6:
            continue
        if len(row[0]) != 8 or not row[0].isdigit():
            continue
        rows.append(row)
        saved += 1
        if len(rows) >= batch:
            yield rows
            rows = []
        if saved >= n:
            break
    if rows:
        yield rows


def real_estabs_chunks(data_dir: Path, batch: int, n: int):
    """Filtros de `load_estabs_bulk` sobre Estabelecimentos0."""
    saved = 0
    rows: list = []
    for row in L.rows_from_zip(L.find_zip(data_dir, "Estabelecimentos0")):
        if len(row) < 30 or len(row[0]) != 8 or not row[0].isdigit():
            continue
        rows.append(row)
        saved += 1
        if len(rows) >= batch:
            yield rows
            rows = []
        if saved >= n:
            break
    if rows:
        yield rows


# ── builders de ops (mesmo formato do loader de referência) ─────────────────

def build_empresas_ops(rows: list) -> list:
    """Corpo de `load_empresas` (load_receita_edn.py:251) sobre rows em
    memória — mesmo RefTids, mesmos atributos, mesmo flush por lote."""
    refs = L.RefTids()
    ops: list = []
    for row in rows:
        tid = refs.fresh()
        ops.append(L.op_add(tid, "empresa/cnpj_base", row[0]))
        if row[1]:
            ops.append(L.op_add(tid, "empresa/razao_social", row[1]))
        if row[2]:
            ops.append(L.op_add(tid, "empresa/natureza_juridica",
                                refs.ref(ops, "natureza/codigo", row[2])))
        if row[3]:
            ops.append(L.op_add(tid, "empresa/qualificacao_resp",
                                refs.ref(ops, "qualificacao/codigo", row[3])))
        if row[4]:
            ops.append(L.op_add(tid, "empresa/capital_social",
                                float(row[4].replace(",", "."))))
        if row[5]:
            ops.append(L.op_add(tid, "empresa/porte", row[5]))
    return ops


class _TxRecorder:
    """Captura os ops que o loader de referência enviaria ao client.tx()."""
    def __init__(self):
        self.ops: list = []

    def tx(self, ops: list) -> dict:
        self.ops = ops
        return {}


def build_estab_ops(rows: list) -> list:
    rec = _TxRecorder()
    L._flush_estab_batch(rec, rows)     # builders idênticos ao harness
    return rec.ops


# ── medição ──────────────────────────────────────────────────────────────────

PHASES = ("read", "build", "wire", "pack", "send", "recv", "unpack")


def cpu_ticks(pid: int) -> float:
    """CPU (s) do processo inteiro: utime+stime de /proc/<pid>/stat."""
    with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as f:
        s = f.read()
    rest = s[s.rfind(")") + 2:].split()
    utime, stime = int(rest[11]), int(rest[12])
    return (utime + stime) / os.sysconf("SC_CLK_TCK")


def find_pids() -> dict[str, int]:
    out: dict[str, int] = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            exe = os.readlink(f"/proc/{entry}/exe")
        except OSError:
            continue
        exe = exe.removesuffix(" (deleted)")
        for name in ("eavt-sql-query", "eavt-sql-query-go",
                     "eavt-sql-transactor", "eavt-sql-transactor-go"):
            if exe.endswith("/" + name):
                out[name] = int(entry)
    return out


def _iter_timed(chunks, ph: dict):
    """Avança o iterador cronometrado. Com `--data-dir` isso é inflate do zip
    + decode CSV + filtro das linhas — o custo real de leitura do cliente no
    harness de referência (que também itera o zip dentro do tempo do estágio)."""
    it = iter(chunks)
    while True:
        t = time.perf_counter()
        try:
            chunk = next(it)
        except StopIteration:
            return
        ph["read"] += time.perf_counter() - t
        yield chunk


def run_stage(client: EavtClient, chunks, build_fn, depth: int,
              pids: dict[str, int], label: str) -> dict:
    ph = dict.fromkeys(PHASES, 0.0)
    rows_total = 0
    inflight = 0

    srv0 = {k: cpu_ticks(v) for k, v in pids.items()}
    cpu0 = time.process_time()
    w0 = time.perf_counter()

    def take_response() -> None:
        t = time.perf_counter()
        raw = client._recv_msg()
        ph["recv"] += time.perf_counter() - t
        t = time.perf_counter()
        resp = msgpack.unpackb(raw, strict_map_key=False)
        ph["unpack"] += time.perf_counter() - t
        if resp.get("error"):
            raise RuntimeError(resp["error"])

    for chunk in _iter_timed(chunks, ph):
        rows_total += len(chunk)
        t = time.perf_counter()
        ops = build_fn(chunk)
        ph["build"] += time.perf_counter() - t
        t = time.perf_counter()
        wire = CC.to_wire(ops)
        ph["wire"] += time.perf_counter() - t
        t = time.perf_counter()
        req = CC._PACKER.pack({"type": "tx", "txdata": wire})
        ph["pack"] += time.perf_counter() - t
        t = time.perf_counter()
        client._send_msg(req)
        ph["send"] += time.perf_counter() - t
        inflight += 1
        if inflight >= depth:
            take_response()
            inflight -= 1
    while inflight:
        take_response()
        inflight -= 1

    wall = time.perf_counter() - w0
    cli = time.process_time() - cpu0
    srv = {k: cpu_ticks(v) - srv0[k] for k, v in pids.items()}

    pct = {k: (v / wall) * 100.0 for k, v in ph.items()} if wall else {}
    return {
        "label": label,
        "rows": rows_total,
        "wall_s": round(wall, 3),
        "rows_per_s": round(rows_total / wall, 1) if wall else 0,
        "phases_s": {k: round(v, 4) for k, v in ph.items()},
        "phases_pct": {k: round(v, 1) for k, v in pct.items()},
        "client_cpu_s": round(cli, 3),
        "client_cpu_pct": round((cli / wall) * 100.0, 1) if wall else 0,
        "server_cpu_pct": {k: round((v / wall) * 100.0, 1)
                           for k, v in srv.items()},
        # ceiling ideal-cliente: se o server respondesse sem custo
        "ideal_client_rows_s": round(rows_total / ph["recv"], 1)
        if ph["recv"] else None,
        # ceiling ideal-servidor: se o cliente não gastasse CPU
        "ideal_server_rows_s": round(rows_total / (wall - ph["recv"]), 1)
        if wall - ph["recv"] > 0 else None,
    }


def chunks_of(rows: list, batch: int):
    for i in range(0, len(rows), batch):
        yield rows[i:i + batch]


def restart_stack(stack: str) -> None:
    env = dict(os.environ, EAVT_STACK=stack)
    subprocess.run([str(_root / "scripts" / "stop.sh")], env=env,
                   capture_output=True, check=True)
    subprocess.run([str(_root / "scripts" / "start.sh")], env=env,
                   capture_output=True, check=True)


def connect(target: str, timeout: float = 20.0, rcvbuf: int = 0) -> EavtClient:
    name = "eavt-transactor.sock" if target == "transactor" else "eavt-query.sock"
    base = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "eavt"
    sp = base / name
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if sp.exists():
            try:
                c = EavtClient(str(sp))
                if rcvbuf:
                    import socket as _socket
                    c._sock.setsockopt(_socket.SOL_SOCKET, _socket.SO_RCVBUF,
                                       rcvbuf)
                return c
            except (ConnectionError, FileNotFoundError, OSError):
                pass
        time.sleep(0.2)
    raise RuntimeError(f"{name} not reachable at {sp}")


def print_stage(st: dict) -> None:
    p = st["phases_pct"]
    print(f"\n-- {st['label']}: {st['rows']:,} rows em {st['wall_s']:.2f}s "
          f"= {st['rows_per_s']:,.0f} rows/s", flush=True)
    print("   fases do cliente (% do wall): "
          + "  ".join(f"{k} {p.get(k, 0):.1f}%" for k in PHASES), flush=True)
    srv = st["server_cpu_pct"]
    srv_txt = "  ".join(f"{k.replace('eavt-sql-', '')} {v}%"
                        for k, v in sorted(srv.items()))
    print(f"   CPU (% de 1 núcleo): cliente {st['client_cpu_pct']}%  ·  "
          f"{srv_txt}", flush=True)
    def fmt(v) -> str:
        return f"{v:,}" if v else "n/d"

    print(f"   teto c/ servidor ideal  {fmt(st['ideal_server_rows_s'])} rows/s"
          f"   ·   teto c/ cliente ideal  {fmt(st['ideal_client_rows_s'])} rows/s",
          flush=True)


BUILD_FNS = {"lookup": build_lookup_ops, "empresas": build_empresas_ops,
             "estabs": build_estab_ops}


def _stage_worker(i, rows, build_name, target, rcvbuf, depth, batch, q, barrier):
    client = None
    try:
        client = connect(target, rcvbuf=rcvbuf)
        barrier.wait()
        st = run_stage(client, chunks_of(rows, batch), BUILD_FNS[build_name],
                       depth, {}, f"{build_name}[proc{i}]")
        q.put({"ok": True, "st": st})
    except BaseException as e:                       # noqa: BLE001
        q.put({"ok": False, "err": repr(e)})
    finally:
        if client is not None:
            try:
                client.close()
            except OSError:
                pass                                 # teardown: con já morta


def parallel_stage(rows, build_name, target, rcvbuf, depth, batch,
                   n_workers) -> dict:
    """Roda o estágio em N processos (fork), cada um com sua conexão —
    mede quanto o servidor aguenta quando o cliente Python não é mais o
    limite de um único processo."""
    import multiprocessing as mp
    ctx = mp.get_context("fork")
    q = ctx.Queue()
    barrier = ctx.Barrier(n_workers + 1)
    slices = [rows[i::n_workers] for i in range(n_workers)]
    procs = [ctx.Process(target=_stage_worker,
                         args=(i, sl, build_name, target, rcvbuf, depth,
                               batch, q, barrier))
             for i, sl in enumerate(slices)]
    pids = find_pids()
    srv0 = {k: cpu_ticks(v) for k, v in pids.items()}
    for p in procs:
        p.start()
    barrier.wait()
    w0 = time.perf_counter()
    outs = [q.get() for _ in procs]
    for p in procs:
        p.join()
    wall = time.perf_counter() - w0
    bad = [o for o in outs if not o["ok"]]
    if bad:
        raise RuntimeError(f"worker falhou: {bad[0]['err']}")
    sts = [o["st"] for o in outs]
    srv = {k: cpu_ticks(v) - srv0[k] for k, v in pids.items()}
    phases = {k: sum(s["phases_s"][k] for s in sts) for k in PHASES}
    cli = sum(s["client_cpu_s"] for s in sts)
    return {
        "label": f"{build_name}x{n_workers}proc",
        "rows": sum(s["rows"] for s in sts),
        "wall_s": round(wall, 3),
        "rows_per_s": round(sum(s["rows"] for s in sts) / wall, 1),
        "phases_s": {k: round(v, 4) for k, v in phases.items()},
        "phases_pct": {k: round(v / wall * 100.0, 1)
                       for k, v in phases.items()},
        "client_cpu_s": round(cli, 3),
        "client_cpu_pct": round(cli / wall * 100.0, 1),
        "server_cpu_pct": {k: round(v / wall * 100.0, 1)
                           for k, v in srv.items()},
        "ideal_server_rows_s": None,
        "ideal_client_rows_s": None,
        "workers": [{"rows": s["rows"], "wall_s": s["wall_s"],
                     "rows_per_s": s["rows_per_s"],
                     "client_cpu_pct": s["client_cpu_pct"]} for s in sts],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--stack", choices=("nim", "go"), default="go")
    ap.add_argument("--target", choices=("query", "transactor"), default="query",
                    help="query = 2 hops (como o harness de referência); "
                         "transactor = 1 hop (isola o hop do query server)")
    ap.add_argument("--depth", type=int, default=1,
                    help="batches em voo (1 = serial, como o harness)")
    ap.add_argument("--n", type=int, default=50_000, help="empresas")
    ap.add_argument("--batch", type=int, default=500)
    ap.add_argument("--label", default="split")
    ap.add_argument("--rcvbuf", type=int, default=0,
                    help="SO_RCVBUF do cliente em bytes (0 = default do kernel) "
                         "— teste de deadlock do pipelining")
    ap.add_argument("--data-dir", type=Path, default=None,
                    help="diretório dos zips REAIS da Receita (ex.: "
                         "/home/ubuntu/dev/dagster_flows/tests_data/receita_zip); "
                         "sem a flag usa linhas sintéticas")
    ap.add_argument("--skip-estabs", action="store_true")
    ap.add_argument("--clients", type=int, default=1,
                    help="processos-cliente paralelos no estágio estabs "
                         "(1 = um único cliente Python, como o harness)")
    args = ap.parse_args()

    os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    os.environ["EAVT_STACK"] = args.stack
    print(f"== stack={args.stack} target={args.target} depth={args.depth} "
          f"n={args.n:,} batch={args.batch} ==", flush=True)
    print("-- restarting stack (fresh DB) --", flush=True)
    restart_stack(args.stack)

    client = connect(args.target, rcvbuf=args.rcvbuf)
    pids = find_pids()
    print(f"-- servers: {pids} --", flush=True)

    n_estabs = int(args.n * 1.3)
    est_rows: list = []
    if args.data_dir:
        d = Path(args.data_dir)
        lookup_iter = real_lookup_chunks(d, args.batch)
        emp_iter = real_empresas_chunks(d, args.batch, args.n)
        est_iter = real_estabs_chunks(d, args.batch, n_estabs)
        if args.clients > 1:      # modo paralelo precisa de lista indexável
            est_rows = [r for ch in real_estabs_chunks(d, args.batch, n_estabs)
                        for r in ch]
    else:
        pools = make_pools()
        rng = random.Random(42)
        lookup_iter = chunks_of(gen_lookup_rows(pools), args.batch)
        emp_iter = chunks_of(gen_empresas(args.n, pools, rng), args.batch)
        if not args.skip_estabs:
            est_rows = gen_estabs(n_estabs, args.n, pools, rng)
        est_iter = chunks_of(est_rows, args.batch)

    results = {
        "meta": {"stack": args.stack, "target": args.target,
                 "depth": args.depth, "n": args.n, "batch": args.batch,
                 "rcvbuf": args.rcvbuf, "clients": args.clients,
                 "data_dir": str(args.data_dir) if args.data_dir else "sintético",
                 "date": time.strftime("%Y-%m-%d %H:%M:%S"),
                 "host": os.uname().nodename},
        "stages": [],
    }

    try:
        t0 = time.perf_counter()
        L.declare_schema(client)
        print(f"-- schema declarado em {time.perf_counter() - t0:.2f}s --",
              flush=True)

        st = run_stage(client, lookup_iter,
                       build_lookup_ops, args.depth, pids, "lookups")
        results["stages"].append(st)
        print_stage(st)

        st = run_stage(client, emp_iter,
                       build_empresas_ops, args.depth, pids, "empresas")
        results["stages"].append(st)
        print_stage(st)

        if not args.skip_estabs:
            if args.clients > 1:
                st = parallel_stage(est_rows, "estabs", args.target,
                                    args.rcvbuf, args.depth, args.batch,
                                    args.clients)
            else:
                st = run_stage(client, est_iter,
                               build_estab_ops, args.depth, pids, "estabs")
            results["stages"].append(st)
            print_stage(st)
    finally:
        client.close()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"client_split_{args.label}.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2)
    print(f"\n[results → {path}]", flush=True)

    load = [s for s in results["stages"] if s["label"] in ("empresas", "estabs")]
    if load:
        rows = sum(s["rows"] for s in load)
        wall = sum(s["wall_s"] for s in load)
        recv = sum(s["phases_s"]["recv"] for s in load)
        client_only = wall - recv
        print("\n=== RESUMO (empresas + estabs) ===")
        print(f"  wall total          {wall:8.2f}s  ({rows / wall:,.0f} rows/s)")
        print(f"  tempo do servidor   {recv:8.2f}s  ({recv / wall * 100:5.1f}%)"
              f"  → teto c/ cliente ideal {rows / recv:,.0f} rows/s")
        print(f"  tempo do cliente    {client_only:8.2f}s  "
              f"({client_only / wall * 100:5.1f}%)"
              f"  → teto c/ servidor ideal {rows / client_only:,.0f} rows/s")
        verdict = ("SERVIDOR" if recv > client_only else "CLIENTE PYTHON")
        print(f"  → gargalo do pipeline serial: {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
