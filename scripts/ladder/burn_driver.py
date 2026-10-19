# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Burn driver: N sandboxes, STEPS execs each burning BURN_S seconds of CPU, ALLOC_GIB resident across steps.

    ATEAPI_ADDR=<node ip>:30443 ATENET_ADDR=<node ip>:30080 python burn_driver.py [N] [STEPS] [GAP_S] [POLICY] [BURN_S] [ALLOC_GIB]

Derived from scripts/oversub_provider.py. Step 0 starts a holder process in the
sandbox that maps ALLOC_GIB and touches every page, then every step burns BURN_S
seconds of CPU on one core and checks that the holder is still alive, so the
memory stays resident across the gaps (and across pause/resume). Prints per-step
latency, return codes, actor states, a per-phase latency table and one summary line.

Env: IMAGE (template image, default localhost:5001/burn:3.12-slim), ATENET_ADDR
(router, default localhost:8000), READY_TIMEOUT_S (1200), EXEC_CONCURRENCY (4096),
STAGGER_S (delay between create starts, 0.05), STATE_EVERY (GetActor every k
steps, 5), PROBE_TIMEOUT_S (660), START_BARRIER (0; 1 = burn only after all N are created), OUT (tsv of every row,
default RUN_DIR/burn-<policy>-<N>.tsv), RUN_DIR (default ~/gym-substrate-run/run), ATESPACE (nemo-gym).
"""

import asyncio
import collections
import os
import signal
import statistics
import sys
import time

import httpx
from nemo_gym.sandbox.providers.base import SandboxSpec

from gym_substrate import SubstrateProvider
from gym_substrate._ateapi import ateapi_pb2


N = int(sys.argv[1]) if len(sys.argv) > 1 else 6
STEPS = int(sys.argv[2]) if len(sys.argv) > 2 else 3
GAP_S = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
POLICY = sys.argv[4] if len(sys.argv) > 4 else "pause_after_exec"
BURN_S = float(sys.argv[5]) if len(sys.argv) > 5 else 20.0
ALLOC_GIB = float(sys.argv[6]) if len(sys.argv) > 6 else 1.0
IMAGE = os.environ.get("IMAGE", "localhost:5001/burn:3.12-slim")
STAGGER_S = float(os.environ.get("STAGGER_S", "0.05"))
RUN_DIR = os.path.expanduser(os.environ.get("RUN_DIR", "~/gym-substrate-run/run"))
OUT = os.path.expanduser(os.environ.get("OUT", f"{RUN_DIR}/burn-{POLICY}-{N}.tsv"))
# GetActor after every step is a control-plane burst of N calls; sample the state
# every STATE_EVERY steps and after a failed step instead.
STATE_EVERY = int(os.environ.get("STATE_EVERY", "5"))
# START_BARRIER=1: every sandbox waits after its create until all N are created,
# so the restore wave runs on a quiet host and the burns start together.
START_BARRIER = os.environ.get("START_BARRIER", "0") == "1"
ALL_CREATED = asyncio.Event()
ATESPACE = os.environ.get("ATESPACE", "nemo-gym")

# The holder maps ALLOC_GIB, writes one byte per 4 KiB page so every page is
# resident on 4 KiB and 64 KiB kernels alike, records its pid and sleeps. It is
# detached from the exec (setsid, nohup, no inherited stdio) so the sandbox
# server's wait on the command's stdout returns when the step is done.
HOLDER_START = (
    "setsid nohup python3 -c 'import mmap,os,time\n"
    "n=%d\nm=mmap.mmap(-1,n)\n"
    "for i in range(0,n,4096): m[i]=1\n"
    'open("/tmp/holder.pid","w").write(str(os.getpid()))\n'
    "time.sleep(10**8)' >/dev/null 2>&1 </dev/null & "
    "for i in $(seq 1 1200); do [ -s /tmp/holder.pid ] && break; sleep 0.5; done; "
) % int(ALLOC_GIB * 2**30)
HOLDER_CHECK = "kill -0 $(cat /tmp/holder.pid 2>/dev/null) 2>/dev/null && echo HOLDER=alive || echo HOLDER=lost; "
BURN = (
    "python3 -c 'import time\nt=time.monotonic()+%g\nx=1.0\nwhile time.monotonic()<t: x=x*1.0000001+1.0'; "
) % BURN_S


def step_command(step: int, start_holder: bool) -> str:
    cmd = ""
    if ALLOC_GIB > 0:
        cmd += (HOLDER_START if start_holder else "") + HOLDER_CHECK
    return cmd + BURN + f"echo STEP={step}"


CREATED = 0
WALL0 = 0.0


async def one_sandbox(provider, idx: int, rows: list) -> None:
    global CREATED
    await asyncio.sleep(idx * STAGGER_S)
    t0 = time.monotonic()
    handle = await provider.create(SandboxSpec(image=IMAGE))
    CREATED += 1
    if CREATED % 10 == 0 or CREATED == N:
        print(f"progress created={CREATED}/{N} t={time.monotonic() - WALL0:.0f}s", flush=True)
    rows.append((idx, "create", time.monotonic() - t0, 0, "", ""))
    if START_BARRIER:
        if CREATED >= N:
            ALL_CREATED.set()
        await ALL_CREATED.wait()
    holder_up = False  # the holder is (re)started on any step that runs without one
    for step in range(STEPS):
        if step:
            await asyncio.sleep(GAP_S)
        t0 = time.monotonic()
        start_holder = ALLOC_GIB > 0 and not holder_up
        # A holder start also pays for the page touching; 600 s covers 3.5 GiB with margin.
        result = await provider.exec(
            handle, step_command(step, start_holder), timeout_s=BURN_S + (600 if start_holder else 120)
        )
        out = result.stdout or ""
        holder = "alive" if "HOLDER=alive" in out else ("lost" if "HOLDER=lost" in out else "none")
        if holder == "alive":
            holder_up = True
        # "lost" only counts when a holder existed or was just started; after a failed step
        # there is nothing to lose and the next step starts one again.
        holder_lost = holder == "lost" and (holder_up or start_holder)
        if holder_lost:
            holder_up = False
        failed = result.return_code != 0 or f"STEP={step}" not in out or holder_lost
        state = ""
        if failed or step % STATE_EVERY == 0 or step == STEPS - 1:
            actor = await provider._control("GetActor", ateapi_pb2.GetActorRequest(actor=handle.raw.object_ref))
            state = ateapi_pb2.ActorState.Name(actor.status.state).removeprefix("ACTOR_STATE_")
        rows.append((idx, f"exec{step}", time.monotonic() - t0, result.return_code, state, holder))
        if failed:
            note = (out or result.stderr or "")[-120:]
            rows.append((idx, "STEP-FAILED", 0.0, result.return_code, state, note))
            print(
                f"STEP-FAILED idx={idx} step={step} rc={result.return_code} state={state} holder={holder} note={note!r}",
                flush=True,
            )
            if state in ("CRASHED", "DELETING"):
                break  # a dead sandbox never comes back; do not grind the remaining steps
    t0 = time.monotonic()
    await provider.close(handle)
    rows.append((idx, "close", time.monotonic() - t0, 0, "", ""))


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(p * (len(values) - 1))))]


async def main() -> int:
    connection = {
        "atespace": ATESPACE,
        "template_namespace": ATESPACE,
        "ateapi_addr": os.environ.get("ATEAPI_ADDR", "localhost:8080"),
        "atenet_addr": os.environ.get("ATENET_ADDR", "localhost:8000"),
    }
    provider = SubstrateProvider(
        connection=connection,
        create={"suspend_policy": POLICY, "ready_timeout_s": float(os.environ.get("READY_TIMEOUT_S", "1200"))},
        exec={"concurrency": int(os.environ.get("EXEC_CONCURRENCY", "4096")), "default_timeout_s": BURN_S + 600},
        # Above the router's parking budget, or a parked probe is cancelled and
        # re-parked at the back of the queue every timeout.
        probe={"timeout_s": float(os.environ.get("PROBE_TIMEOUT_S", "660"))},
    )
    # The provider's own client keeps httpx's default pool of 100 connections,
    # which would cap in-flight execs at 100; give it an unbounded pool.
    provider._http_client = httpx.AsyncClient(
        base_url=f"http://{connection['atenet_addr']}",
        limits=httpx.Limits(max_connections=None, max_keepalive_connections=4096),
    )
    rows: list = []

    # SIGUSR1 prints every task's await stack: the way to see where a stalled
    # run is waiting without ptrace.
    def dump_tasks(*_):
        for t in asyncio.all_tasks():
            frames = t.get_stack(limit=6)
            where = " <- ".join(f"{f.f_code.co_name}:{f.f_lineno}" for f in frames)
            print(f"TASK {t.get_name()} done={t.done()} {where}", flush=True)

    asyncio.get_running_loop().add_signal_handler(signal.SIGUSR1, dump_tasks)
    # One RPC before the herd: the channel connects on it, so the N creates
    # that follow start on a READY channel.
    await provider._control("ListActors", ateapi_pb2.ListActorsRequest(atespace=ATESPACE, page_size=1))
    global WALL0
    WALL0 = wall0 = time.monotonic()
    results = await asyncio.gather(*(one_sandbox(provider, i, rows) for i in range(N)), return_exceptions=True)
    wall = time.monotonic() - wall0
    await provider.aclose()

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        for row in sorted(rows):
            f.write("%d\t%s\t%.2f\t%s\t%s\t%s\n" % row)
    errors = [r for r in results if isinstance(r, Exception)]
    for e in errors[:20]:
        print("ERROR", repr(e)[:300])
    failed = [r for r in rows if r[1] == "STEP-FAILED"]
    for r in failed[:20]:
        print("STEP-FAILED", r)
    print(
        f"{'phase':8s} {'n':>5s} {'median':>8s} {'p90':>8s} {'p99':>8s} {'max':>8s}  (exec latency includes any resume and queueing; burn is {BURN_S:g}s)"
    )
    for phase in ("create",) + tuple(f"exec{s}" for s in range(STEPS)) + ("close",):
        lat = [r[2] for r in rows if r[1] == phase]
        if lat:
            print(
                f"{phase:8s} {len(lat):5d} {statistics.median(lat):7.1f}s {pct(lat, 0.9):7.1f}s {pct(lat, 0.99):7.1f}s {max(lat):7.1f}s"
            )
    last = collections.Counter(r[4] for r in rows if r[1] == f"exec{STEPS - 1}")
    holder = collections.Counter(r[5] for r in rows if r[1].startswith("exec"))
    print(
        f"policy={POLICY} sandboxes={N} steps={STEPS} gap={GAP_S:g}s burn={BURN_S:g}s alloc={ALLOC_GIB:g}GiB "
        f"wall={wall:.1f}s created={sum(1 for r in rows if r[1] == 'create')} closed={sum(1 for r in rows if r[1] == 'close')} "
        f"errors={len(errors)} step_failed={len(failed)} rc_failed={sum(1 for r in failed if r[3] != 0)} "
        f"holder_lost={sum(1 for r in rows if r[1].startswith('exec') and r[5] == 'lost')} holder={dict(holder)} states_after_last_step={dict(last)} rows={OUT}"
    )
    ok = not errors and not failed
    print("RESULT", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
