# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""How much host memory one sandbox of an image takes, and what its pause and resume cost.

    ATEAPI_ADDR=<node ip>:30443 ATENET_ADDR=<node ip>:30080 python scripts/probes/guest_memory.py IMAGE

Creates one sandbox (suspend policy never) and reads, at each step, the guest's own view
(`free -m`, `df /`) and the host's: the resident size of the sandbox's processes on its worker pod
(for the micro-VM class the VMM and virtiofsd; for gVisor the runsc sandbox), found by the actor's
UID in their command lines on the kind node that runs the worker (the worker image has no shell, so
the node container is asked through docker). Steps: idle; after a page-cache fill (every regular file under 64 MiB
read once, bounded by FILL_TIMEOUT_S); after `echo 3 > drop_caches` in the guest; then one pause
(timed, with the node-local snapshot files' sizes) and one resume (timed, the first exec after it).
Needs kubectl against the cluster. Prints a table and ends with RESULT PASS when every step ran.
"""

import asyncio
import os
import subprocess
import sys
import time

from nemo_gym.sandbox.providers.base import SandboxSpec

from gym_substrate import SubstrateProvider
from gym_substrate._ateapi import ateapi_pb2


IMAGE = sys.argv[1] if len(sys.argv) > 1 else "python:3.12-slim"
ATESPACE = os.environ.get("ATESPACE", "nemo-gym")
FILL_TIMEOUT_S = float(os.environ.get("FILL_TIMEOUT_S", "600"))
GUEST_VIEW = 'free -m | awk \'NR==2 {print "guest_total_mb=" $2, "used_mb=" $3, "cache_mb=" $6, "avail_mb=" $7}\'; df -m / | awk \'NR==2 {print "rootfs_used_mb=" $3}\''


def sh(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120).stdout


async def actor_info(provider, handle) -> tuple[str, str, str]:
    actor = await provider._control("GetActor", ateapi_pb2.GetActorRequest(actor=handle.raw.object_ref))
    state = ateapi_pb2.ActorState.Name(actor.status.state).removeprefix("ACTOR_STATE_")
    pod = actor.status.worker_assignment.worker_pod if actor.status.HasField("worker_assignment") else ""
    return actor.metadata.uid, state, pod


def node_of(pod: str) -> str:
    """The kind node container that runs the worker pod (empty when unknown)."""
    if not pod or "/" not in pod:
        return ""
    ns, name = pod.split("/", 1)
    return sh(["kubectl", "-n", ns, "get", "pod", name, "-o", "jsonpath={.spec.nodeName}"]).strip()


def host_rss_kb(node: str, uid: str) -> tuple[int, int]:
    """Resident KiB of the processes whose command line names the actor UID, on the node, and their count."""
    if not node:
        return 0, 0
    script = (
        "for p in /proc/[0-9]*; do if tr '\\0' ' ' < $p/cmdline 2>/dev/null | grep -q " + uid + "; then "
        "awk '/^VmRSS/ {print $2}' $p/status; fi; done"
    )
    out = sh(["docker", "exec", node, "sh", "-c", script])
    rows = [int(x) for x in out.split() if x.isdigit()]
    return sum(rows), len(rows)


def snapshot_files_kb(node: str, uid: str) -> str:
    """Apparent and allocated sizes of the actor's node-local checkpoint files."""
    if not node:
        return "n/a"
    script = (
        f"find / \\( -path /proc -o -path /sys -o -path /dev \\) -prune -o -path '*{uid}*' "
        "\\( -name memory-ranges -o -name '*.tar' -o -name state.json \\) -print 2>/dev/null | "
        'while read -r f; do printf \'%s apparent_kb=%s alloc_kb=%s; \' "${f##*/}" "$(du -k --apparent-size "$f" | cut -f1)" "$(du -k "$f" | cut -f1)"; done'
    )
    out = sh(["docker", "exec", node, "sh", "-c", script])
    return out.strip() or "none"


async def main() -> int:
    provider = SubstrateProvider(
        connection={
            "atespace": ATESPACE,
            "template_namespace": ATESPACE,
            "ateapi_addr": os.environ.get("ATEAPI_ADDR", "localhost:8080"),
            "atenet_addr": os.environ.get("ATENET_ADDR", "localhost:8000"),
        },
        create={"suspend_policy": "never", "ready_timeout_s": 900},
        exec={"default_timeout_s": FILL_TIMEOUT_S + 60},
    )
    failures = 0
    t0 = time.monotonic()
    handle = await provider.create(SandboxSpec(image=IMAGE))
    uid, state, pod = await actor_info(provider, handle)
    node = node_of(pod)
    print(
        f"create    {time.monotonic() - t0:6.1f}s  id={handle.sandbox_id} uid={uid} state={state} pod={pod} node={node}"
    )

    async def row(label: str, cmd: str, timeout_s: float = 120) -> None:
        nonlocal failures
        t = time.monotonic()
        r = await provider.exec(handle, cmd, timeout_s=timeout_s)
        kb, n = host_rss_kb(node, uid)
        guest = " ".join((r.stdout or "").split())
        print(
            f"{label:9s} {time.monotonic() - t:6.1f}s  rc={r.return_code} host_rss_mb={kb // 1024} procs={n} {guest}"
        )
        failures += r.return_code != 0

    await row("idle", GUEST_VIEW)
    await row(
        "fill",
        f"find / -xdev -type f -size -64M -print0 2>/dev/null | xargs -0 cat > /dev/null 2>&1; {GUEST_VIEW}",
        FILL_TIMEOUT_S,
    )
    await row("dropped", f"sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; {GUEST_VIEW}")

    t = time.monotonic()
    await provider.pause(handle)
    uid, state, pod_after = await actor_info(provider, handle)
    print(f"pause     {time.monotonic() - t:6.1f}s  state={state} snapshot: {snapshot_files_kb(node, uid)}")
    failures += state != "SUSPENDED"

    t = time.monotonic()
    r = await provider.exec(handle, GUEST_VIEW, timeout_s=600)
    uid, state, pod_after = await actor_info(provider, handle)
    kb, n = host_rss_kb(node_of(pod_after) or node, uid)
    print(
        f"resume    {time.monotonic() - t:6.1f}s  rc={r.return_code} state={state} host_rss_mb={kb // 1024} procs={n} {' '.join((r.stdout or '').split())}"
    )
    failures += r.return_code != 0

    t = time.monotonic()
    await provider.close(handle)
    print(f"close     {time.monotonic() - t:6.1f}s")
    await provider.aclose()
    print("RESULT", "PASS" if failures == 0 else f"FAIL ({failures})")
    return failures


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
