#!/usr/bin/env python3
"""bench_cpu_dist.py — distribuição de CPU entre transactor, query server e
cliente durante uma carga real.

Amostra `/proc/<pid>/stat` (utime+stime) a cada 50 ms para os três processos e
reporta, por processo: CPU-s, % de 1 núcleo (média e pico por janela de 200 ms)
e a fatia do CPU total da rodada. Responde "quem come o CPU" e — combinado com
o fato de o pipeline ser serial (1 batch em voo) — "quem é a restrição".

O cliente é identificado por regex no cmdline (`--client-match`, repetível);
a cadeia de ancestrais do próprio sampler (uv/shell) é excluída, e vários pids
que casam são SOMADOS (ex.: `uv run` + `python …bench_receita_hydrated.py`).

Uso:
    uv run python tests/bench_cpu_dist.py --stack go --label allgo \
        --client-match 'eavt-sql-load-go' \
        -- ./build/eavt-sql-load-go -n 50000 -max-simples 55000 \
           -max-estabs 65000 -max-socios 25000 -data-dir <zips>
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from bench_client_split import cpu_ticks, find_pids  # noqa: E402

OUT_DIR = Path("/tmp/opencode/receita_bench")
TICK = 0.05          # amostragem
WINDOW = 0.2         # janela do pico


def ancestors() -> set[int]:
    """pids do sampler e de seus pais (uv/shell) — nunca são 'cliente'."""
    out: set[int] = set()
    pid = os.getpid()
    while pid and pid not in out:
        out.add(pid)
        try:
            with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as f:
                s = f.read()
            ppid = int(s[s.rfind(")") + 2:].split()[1])
        except (OSError, IndexError, ValueError):
            break
        pid = ppid
    return out


def find_by_cmdline(pattern: str, skip: set[int]) -> list[int]:
    """pids (fora de `skip`) cujo cmdline casa com `pattern` (regex)."""
    out = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) in skip:
            continue
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as f:
                cmd = f.read().replace(b"\x00", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        if re.search(pattern, cmd):
            out.append(int(entry))
    return out


class Sampler(threading.Thread):
    def __init__(self, exe_subs: dict[str, str], patterns: dict[str, str],
                 skip: set[int]):
        super().__init__(daemon=True)
        self.exe_subs = exe_subs              # label → sufixo do /proc/pid/exe
        self.patterns = patterns              # label → regex (clientes)
        self.skip = skip
        self.stop_ev = threading.Event()
        self.cpu_s: dict[str, float] = {}
        self.windows: dict[str, list[float]] = {}
        self._last: dict[str, float] = {}
        self._win_delta: dict[str, float] = {}
        self._win_start = time.perf_counter()

    def _resolve(self) -> dict[str, list[int]]:
        # servidores resolvidos a CADA tick: o harness Python reinicia o stack
        # (DB fresco por tamanho), trocando os pids no meio da rodada.
        out: dict[str, list[int]] = {}
        live = find_pids()
        for label, substr in self.exe_subs.items():
            for key, pid in live.items():
                if substr in key:
                    out[label] = [pid]
        for label, pat in self.patterns.items():
            pids = find_by_cmdline(pat, self.skip)
            if pids:
                out[label] = pids
        return out

    def run(self) -> None:
        while not self.stop_ev.is_set():
            now = time.perf_counter()
            for label, pids in self._resolve().items():
                total = 0.0
                for pid in pids:
                    try:
                        total += cpu_ticks(pid)
                    except (OSError, ProcessLookupError, IndexError, ValueError):
                        continue
                prev = self._last.get(label)
                self._last[label] = total
                if prev is None:
                    continue
                d = max(0.0, total - prev)
                self.cpu_s[label] = self.cpu_s.get(label, 0.0) + d
                self._win_delta[label] = self._win_delta.get(label, 0.0) + d
            if now - self._win_start >= WINDOW:
                for label, d in self._win_delta.items():
                    self.windows.setdefault(label, []).append(
                        d / (now - self._win_start) * 100.0)
                    self._win_delta[label] = 0.0
                self._win_start = now
            time.sleep(TICK)

    def peak(self, label: str) -> float:
        w = self.windows.get(label) or []
        return max(w) if w else 0.0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--stack", choices=("nim", "go"), default="go")
    ap.add_argument("--label", default="cpu")
    ap.add_argument("--client-match", action="append", default=[],
                    help="regex do cmdline do cliente (repetível)")
    ap.add_argument("--cmd2", default="",
                    help="segundo comando de cliente, rodado em PARALELO "
                         "(teste de headroom do servidor)")
    ap.add_argument("cmd", nargs=argparse.REMAINDER,
                    help="comando do cliente (precedido por --)")
    args = ap.parse_args()

    os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    os.environ["EAVT_STACK"] = args.stack
    cmd = args.cmd[1:] if args.cmd[:1] == ["--"] else args.cmd
    if not cmd:
        ap.error("falta o comando do cliente depois de --")

    print(f"== stack={args.stack} label={args.label} ==", flush=True)
    env = dict(os.environ, EAVT_STACK=args.stack)
    subprocess.run([str(_root / "scripts" / "stop.sh")], env=env,
                   capture_output=True, check=True)
    subprocess.run([str(_root / "scripts" / "start.sh")], env=env,
                   capture_output=True, check=True)
    time.sleep(0.5)

    exe_subs = {"transactor": "eavt-sql-transactor", "query": "eavt-sql-query"}
    patterns = {f"client:{i}": p for i, p in enumerate(args.client_match)}
    skip = ancestors()
    print(f"-- servidores: {exe_subs} · clientes: {patterns} · "
          f"skip: {sorted(skip)}", flush=True)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    log = OUT_DIR / f"cpu_{args.label}.log"
    log2 = OUT_DIR / f"cpu_{args.label}_b.log"
    t0 = time.perf_counter()
    with open(log, "w", encoding="utf-8") as lf:
        proc = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, env=env)
        proc2 = None
        lf2 = None
        if args.cmd2:
            import shlex
            lf2 = open(log2, "w", encoding="utf-8")
            proc2 = subprocess.Popen(shlex.split(args.cmd2), stdout=lf2,
                                     stderr=subprocess.STDOUT, env=env)
        sm = Sampler(exe_subs, patterns, skip)
        sm.start()
        rc = proc.wait()
        rc2 = proc2.wait() if proc2 is not None else 0
        wall = time.perf_counter() - t0
        sm.stop_ev.set()
        sm.join(timeout=1.0)
        if lf2 is not None:
            lf2.close()

    print(f"-- cliente saiu com rc={rc}"
          + (f" · cmd2 rc={rc2}" if args.cmd2 else "")
          + f", wall={wall:.2f}s --", flush=True)
    for lf in (log, log2) if args.cmd2 else (log,):
        if not lf.exists():
            continue
        for line in lf.read_text(encoding="utf-8", errors="replace").splitlines():
            if "[t]" in line or "Error" in line or "first empresa" in line:
                print(f"   [{lf.stem}] {line}", flush=True)

    total = sum(sm.cpu_s.values()) or 1.0
    rows = []
    for label in sorted(sm.cpu_s, key=lambda k: -sm.cpu_s[k]):
        cpu = sm.cpu_s[label]
        rows.append({
            "processo": label,
            "cpu_s": round(cpu, 2),
            "pct_core": round(cpu / wall * 100.0, 1),
            "pico_pct_core": round(sm.peak(label), 0),
            "fatia": round(cpu / total * 100.0, 1),
        })

    print(f"\n=== DISTRIBUIÇÃO DE CPU (wall {wall:.2f}s, stack={args.stack}) ===")
    print(f"{'processo':<30}{'cpu-s':>8}{'% núcleo':>10}{'pico':>8}{'fatia':>8}")
    for r in rows:
        print(f"{r['processo']:<30}{r['cpu_s']:>8.2f}{r['pct_core']:>9.1f}%"
              f"{r['pico_pct_core']:>7.0f}%{r['fatia']:>7.1f}%")
    print(f"{'TOTAL':<30}{total:>8.2f}")

    path = OUT_DIR / f"cpu_{args.label}.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"stack": args.stack, "label": args.label,
                   "wall_s": round(wall, 3), "cmd": cmd,
                   "processes": rows}, f, indent=2)
    print(f"[results → {path}]", flush=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
