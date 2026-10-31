#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Summarize the micro-VM worker's "Actor restore phases" log lines.

    python3 scripts/ladder/restore_phases.py FILE...

One line per restore, JSON (slog durations in nanoseconds) or text (key=value with Go
durations). Prints per phase n, min, median, p90 and max, then the reseeds over 5 s and the
five slowest. Standard library only.
"""

import json
import re
import statistics
import sys


PHASES = ("vm_restore", "reseed", "wakeup_probe", "total")
SLOW_RESEED_S = 5.0
_UNIT_S = {"h": 3600.0, "m": 60.0, "s": 1.0, "ms": 1e-3, "µs": 1e-6, "us": 1e-6, "ns": 1e-9}
_TEXT_FIELD = re.compile(r'(\w+)=("[^"]*"|\S+)')


def seconds(value) -> float:
    """A slog duration: nanoseconds as a number, or a Go duration string such as 1m2.5s."""
    if isinstance(value, (int, float)):
        return value / 1e9
    total = 0.0
    for number, unit in re.findall(r"([\d.]+)(h|ms|µs|us|ns|m|s)", str(value)):
        total += float(number) * _UNIT_S[unit]
    return total


def parse(line: str) -> dict | None:
    line = line.strip()
    if not line:
        return None
    if line.startswith("{"):
        record = json.loads(line)
    else:
        record = {k: v.strip('"') for k, v in _TEXT_FIELD.findall(line)}
    if record.get("msg") != "Actor restore phases":
        return None
    out = {phase: seconds(record[phase]) for phase in PHASES if phase in record}
    out["id"], out["time"] = record.get("id", "?"), record.get("time", "")
    return out


def pct(values: list[float], p: float) -> float:
    v = sorted(values)
    return v[min(len(v) - 1, round(p * (len(v) - 1)))]


def summarize(records: list[dict]) -> list[str]:
    lines = [f"restores: {len(records)}"]
    for phase in PHASES:
        values = [r[phase] for r in records if phase in r]
        if values:
            lines.append(
                f"{phase}: n={len(values)} min={min(values):.2f}s median={statistics.median(values):.2f}s "
                f"p90={pct(values, 0.9):.2f}s max={max(values):.2f}s"
            )
    reseeds = sorted((r for r in records if "reseed" in r), key=lambda r: r["reseed"], reverse=True)
    lines.append(
        f"reseed over {SLOW_RESEED_S:g}s: {sum(r['reseed'] > SLOW_RESEED_S for r in reseeds)} of {len(reseeds)}"
    )
    lines += [f"slow reseed {r['reseed']:.2f}s at {r['time'][:19]} actor {r['id'][:8]}" for r in reseeds[:5]]
    return lines


def main(paths: list[str]) -> int:
    records = []
    for path in paths:
        with open(path, errors="replace") as f:
            records += [r for r in (parse(line) for line in f) if r]
    print(f"restore phases: {len(records)} lines from {', '.join(paths)}")
    print("\n".join(summarize(records)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
