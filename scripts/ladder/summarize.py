#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""One markdown table row per arm of a ladder run.

    python3 scripts/ladder/summarize.py DIR [--label TEXT] [--no-header]

DIR is the run dir of ladder.sh or its ladder/ output dir. The inputs are read from DIR
and its parent: events.log (or the ladder-chain-*.log files there or in the logs dir next
to the run dir; a later file wins for an arm that appears twice), the burn rows <arm>-<shard>.tsv of burn_driver.py,
<arm>-snaps.txt, <arm>-samples.txt and host-samples.txt. Columns: arm, N, result, wall,
first step, step or rollout median, p99, errors, crashes, host memory peak and the
control-plane restarts during the arm. A cell stays empty when its input is missing.
Standard library only.
"""

import argparse
import re
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path


BURN_START = re.compile(r"^(\S+Z) ladder: start (\S+): image ")
GYM_START = re.compile(r"^(\S+Z) ladder: start (\S+) \(run_arm ")
END = re.compile(r"^(\S+Z) ladder: end (\S+) rc=(\d+)")
SHARD = re.compile(r"^shard \d+: (policy=.*)$")
RESULT = re.compile(r"^shard \d+: RESULT (PASS|FAIL)")
GYM = re.compile(
    r"policy=suspend_policy: (\S+) n=(\d+) wall=(\d+)s eval_exit=(\d+) leaked_actors=(\d+) start=(\S+) end=(\S+)"
)
LATENCY = re.compile(r"median ([\d.]+) min, p90 ([\d.]+) min, p99 ([\d.]+) min")
ROLLOUTS = re.compile(r"rollouts=(\d+) reward_mean=([\d.]+) errored=(\d+)")
HOST = re.compile(r"^(\S+Z) busy=(\d+)% mem_used=(\d+)G")
COLUMNS = [
    "arm",
    "N",
    "result",
    "wall",
    "first step",
    "median",
    "p99",
    "errors",
    "crashes",
    "host mem peak",
    "restarts",
]


def stamp(s: str) -> datetime:
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def pct(values: list[float], p: float) -> float:
    v = sorted(values)
    return v[min(len(v) - 1, round(p * (len(v) - 1)))]


def event_files(d: Path) -> list[Path]:
    """Chain logs in name order, then events.log: the newest record of an arm wins."""
    bases = (d, d.parent, d.parent / "logs", d.parent.parent / "logs")
    chains = sorted({p for base in bases for p in base.glob("ladder-chain-*.log")})
    return chains + [p for p in (d.parent / "events.log", d / "events.log") if p.is_file()]


def parse_events(paths: list[Path]) -> dict[str, dict]:
    """Per arm: start, end, rc, kind, shard summaries, results, stop rules and the Gym runner lines."""
    arms: dict[str, dict] = {}
    for path in paths:
        current = None
        for line in path.read_text(errors="replace").splitlines():
            m = BURN_START.match(line) or GYM_START.match(line)
            if m:
                kind = "burn" if m.re is BURN_START else "gym"
                current = arms[m.group(2)] = {
                    "kind": kind,
                    "start": stamp(m.group(1)),
                    "shards": [],
                    "results": [],
                    "stops": [],
                }
                continue
            m = END.match(line)
            if m:
                current = arms.setdefault(m.group(2), {"kind": "burn", "shards": [], "results": [], "stops": []})
                current.update(end=stamp(m.group(1)), rc=int(m.group(3)))
                continue
            if line.startswith("20") and " ladder: " in line:
                if "STOP RULE" in line and current is not None:
                    current["stops"].append(line.split("STOP RULE: ", 1)[1])
                continue
            if current is None:
                continue
            if m := SHARD.match(line):
                current["shards"].append(
                    dict(kv.split("=", 1) for kv in m.group(1).split(" ") if "=" in kv and "{" not in kv)
                )
            elif m := RESULT.match(line):
                current["results"].append(m.group(1))
            elif m := GYM.search(line):
                current.update(
                    kind="gym", policy=m.group(1), n=int(m.group(2)), wall=int(m.group(3)), eval_exit=int(m.group(4))
                )
                current.update(leaked=int(m.group(5)), run_start=stamp(m.group(6)), run_end=stamp(m.group(7)))
            elif m := LATENCY.search(line):
                current.update(median_min=float(m.group(1)), p99_min=float(m.group(3)))
            elif m := ROLLOUTS.search(line):
                current.update(reward=float(m.group(2)), errored=int(m.group(3)))
    return arms


def find(d: Path, name: str) -> Path | None:
    for base in (d, d.parent):
        if (base / name).is_file():
            return base / name
    return None


def read_rows(d: Path, arm: str) -> list[list[str]]:
    """The burn rows of every shard: idx, phase, seconds, rc, state, holder."""
    rows = []
    for base in (d, d.parent):
        files = sorted(base.glob(f"{arm}-[0-9]*.tsv"))
        if files:
            for f in files:
                rows += [c for c in (ln.split("\t") for ln in f.read_text().splitlines()) if len(c) >= 4]
            break
    return rows


def max_crashed(path: Path | None) -> int:
    if path is None:
        return 0
    return max([int(m.group(1)) for m in re.finditer(r"(\d+) (?:ACTOR_STATE_)?CRASHED", path.read_text())] or [0])


def restarts(path: Path | None) -> str:
    if path is None:
        return ""
    r = [int(m.group(1)) for m in re.finditer(r"restarts (\d+)", path.read_text())]
    return str(r[-1] - r[0]) if r else ""


def host_peak(samples: list[tuple[datetime, int]], start, end) -> str:
    if start is None or end is None:
        return ""
    window = [g for t, g in samples if start <= t <= end]
    return f"{max(window)} G" if window else ""


def burn_row(arm: str, ev: dict, rows: list[list[str]], d: Path, samples) -> list[str]:
    created = sum(1 for c in rows if c[1] == "create")
    closed = sum(1 for c in rows if c[1] == "close")
    execs = [c for c in rows if c[1].startswith("exec")]
    first = [float(c[2]) for c in execs if c[1] == "exec0"]
    times = [float(c[2]) for c in execs]
    steps = len({c[1] for c in execs})
    errors = sum(1 for c in execs if c[3] not in ("0", "")) + sum(1 for c in execs if len(c) > 5 and c[5] == "lost")
    errors += sum(int(s.get("errors", 0)) for s in ev.get("shards", []))
    snaps = find(d, f"{arm}-snaps.txt")
    crashed = max(max_crashed(snaps), len({c[0] for c in execs if c[4] == "CRASHED"}))
    crashes = crashed + sum(1 for c in rows if c[1] == "STEP-FAILED")
    if "rc" not in ev:
        result = ""
    else:
        ok = ev["rc"] == 0 and not ev["stops"] and "FAIL" not in ev["results"] and created == closed and crashes == 0
        result = "PASS" if ok else "FAIL"
    start, end = ev.get("start"), ev.get("end")
    wall = f"{(end - start).total_seconds():.0f} s" if start and end else ""
    return [
        arm,
        f"{created} x {steps} steps" if rows else "",
        result,
        wall,
        f"{statistics.median(first):.1f} s" if first else "",
        f"{statistics.median(times):.1f} s" if times else "",
        f"{pct(times, 0.99):.1f} s" if times else "",
        str(errors),
        str(crashes),
        host_peak(samples, start, end),
        restarts(snaps),
    ]


def gym_row(arm: str, ev: dict, d: Path, samples) -> list[str]:
    snaps = find(d, f"{arm}-snaps.txt")
    crashes = max(max_crashed(snaps), max_crashed(find(d, f"{arm}-samples.txt")))
    errors = ev.get("errored", 0) + ev.get("leaked", 0)
    if "rc" not in ev:
        result = ""
    elif ev["rc"] == 124:
        result = "TIMEBOX"
    else:
        result = (
            "PASS"
            if ev["rc"] == 0 and ev.get("eval_exit", 1) == 0 and errors == 0 and crashes == 0 and not ev["stops"]
            else "FAIL"
        )
    start, end = ev.get("run_start", ev.get("start")), ev.get("run_end", ev.get("end"))
    return [
        arm,
        f"{ev['n']} rollouts" if "n" in ev else "",
        result,
        f"{ev['wall']} s" if "wall" in ev else "",
        "",
        f"{ev['median_min']} min" if "median_min" in ev else "",
        f"{ev['p99_min']} min" if "p99_min" in ev else "",
        str(errors),
        str(crashes),
        host_peak(samples, start, end),
        restarts(snaps),
    ]


def summarize(d: Path) -> list[list[str]]:
    arms = parse_events(event_files(d))
    for base in (d, d.parent):  # burn arms with rows but no events
        for f in base.glob("*-[0-9].tsv"):
            arms.setdefault(f.name.rsplit("-", 1)[0], {"kind": "burn", "shards": [], "results": [], "stops": []})
    samples = []
    if hs := find(d, "host-samples.txt"):
        samples = [(stamp(m.group(1)), int(m.group(3))) for ln in hs.read_text().splitlines() if (m := HOST.match(ln))]
    out = []
    for arm, ev in sorted(
        arms.items(), key=lambda kv: (kv[1].get("start") or datetime.max.replace(tzinfo=timezone.utc), kv[0])
    ):
        rows = read_rows(d, arm) if ev["kind"] == "burn" else []
        out.append(burn_row(arm, ev, rows, d, samples) if ev["kind"] == "burn" else gym_row(arm, ev, d, samples))
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dir", type=Path)
    ap.add_argument(
        "--label", help="text for a first column (for example the host) when rows of several runs are joined"
    )
    ap.add_argument("--no-header", action="store_true")
    args = ap.parse_args(argv)
    rows = summarize(args.dir.resolve())
    if not rows:
        print(f"no arms found under {args.dir}", file=sys.stderr)
        return 1
    header = (["label"] if args.label else []) + COLUMNS
    if not args.no_header:
        print("| " + " | ".join(header) + " |")
        print("|" + "---|" * len(header))
    for r in rows:
        print("| " + " | ".join(([args.label] if args.label else []) + r) + " |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
