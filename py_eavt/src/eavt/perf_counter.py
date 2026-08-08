"""perf_counter.py — Timing probes for hot-path analysis.

Usage:
    import perf_counter as pc
    pc.reset()
    # ... run benchmark ...
    pc.report()
"""
import time
from collections import defaultdict

_times: dict[str, list[float]] = defaultdict(list)
_enabled = True


def reset():
    _times.clear()


def enable():
    global _enabled
    _enabled = True


def disable():
    global _enabled
    _enabled = False


class Timer:
    """Context manager that records elapsed time."""
    __slots__ = ("_name", "_start")
    def __init__(self, name: str):
        self._name = name
    def __enter__(self):
        self._start = time.perf_counter()
        return self
    def __exit__(self, *_):
        if _enabled:
            _times[self._name].append(time.perf_counter() - self._start)


def record(name: str, elapsed: float):
    """Record a single elapsed time."""
    if _enabled:
        _times[name].append(elapsed)


def report():
    """Print timing report sorted by total time."""
    if not _times:
        print("(no timing data)")
        return
    rows = []
    for name, samples in _times.items():
        total = sum(samples) * 1000
        count = len(samples)
        avg = total / count if count else 0
        rows.append((total, count, avg, name))
    rows.sort(reverse=True)
    print(f"\n{'name':40s} {'total ms':>10s} {'count':>10s} {'avg µs':>10s}")
    print("-" * 75)
    for total, count, avg, name in rows:
        print(f"{name:40s} {total:10.1f} {count:10d} {avg*1000:10.1f}")
