# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""What a cancelled or repeated pause does to an actor on this cluster.

    ATEAPI_ADDR=<node ip>:30443 ATENET_ADDR=<node ip>:30080 python scripts/probes/cancelled_pause.py [IMAGE]

Creates one sandbox (suspend policy never), runs a command, then:
  1. starts SuspendActor and drops the client call after CANCEL_AFTER_S (default 0.3 s): the server
     is expected to finish the checkpoint on its own (Substrate #2558), so the actor ends SUSPENDED;
  2. sends a second SuspendActor right after: on gVisor a retried checkpoint used to crash the actor
     (Substrate #2491); the micro-VM class has no such fix;
  3. runs a command again, which resumes the actor through the router.
Prints the state after each step and ends with RESULT PASS when the actor is SUSPENDED after 1,
not CRASHED after 2, and the exec of 3 returns 0.
"""

import asyncio
import os
import sys
import time

import grpc
from nemo_gym.sandbox.providers.base import SandboxSpec

from gym_substrate import SubstrateProvider
from gym_substrate._ateapi import ateapi_pb2


IMAGE = sys.argv[1] if len(sys.argv) > 1 else "python:3.12-slim"
ATESPACE = os.environ.get("ATESPACE", "nemo-gym")
CANCEL_AFTER_S = float(os.environ.get("CANCEL_AFTER_S", "0.3"))
SETTLE_S = float(os.environ.get("SETTLE_S", "180"))


async def state(provider, handle) -> str:
    actor = await provider._control("GetActor", ateapi_pb2.GetActorRequest(actor=handle.raw.object_ref))
    return ateapi_pb2.ActorState.Name(actor.status.state).removeprefix("ACTOR_STATE_")


async def settle(provider, handle, want: set[str]) -> str:
    deadline = time.monotonic() + SETTLE_S
    while True:
        s = await state(provider, handle)
        if s in want or s in ("CRASHED", "DELETING") or time.monotonic() >= deadline:
            return s
        await asyncio.sleep(1)


async def main() -> int:
    provider = SubstrateProvider(
        connection={
            "atespace": ATESPACE,
            "template_namespace": ATESPACE,
            "ateapi_addr": os.environ.get("ATEAPI_ADDR", "localhost:8080"),
            "atenet_addr": os.environ.get("ATENET_ADDR", "localhost:8000"),
        },
        create={"suspend_policy": "never", "ready_timeout_s": 900},
    )
    failures = 0
    handle = await provider.create(SandboxSpec(image=IMAGE))
    r = await provider.exec(handle, "echo warm", timeout_s=60)
    print(f"create    id={handle.sandbox_id} state={await state(provider, handle)} warm rc={r.return_code}")

    request = ateapi_pb2.SuspendActorRequest(
        actor=handle.raw.object_ref,
        options=ateapi_pb2.SuspendOptions(mode=ateapi_pb2.DurabilityMode.DURABILITY_MODE_ASYNCHRONOUS),
    )
    t0 = time.monotonic()
    try:
        await asyncio.wait_for(provider._control("SuspendActor", request), timeout=CANCEL_AFTER_S)
        print(f"cancel    the suspend returned within {CANCEL_AFTER_S} s; nothing to cancel")
    except asyncio.TimeoutError:
        print(f"cancel    client call dropped after {CANCEL_AFTER_S} s")
    s1 = await settle(provider, handle, {"SUSPENDED"})
    print(f"step 1    state={s1} after {time.monotonic() - t0:.1f} s (want SUSPENDED)")
    failures += s1 != "SUSPENDED"

    try:
        await provider._control("SuspendActor", request)
        print("step 2    second SuspendActor accepted")
    except grpc.aio.AioRpcError as e:
        print(f"step 2    second SuspendActor: {e.code().name}: {e.details()}")
    s2 = await settle(provider, handle, {"SUSPENDED"})
    print(f"step 2    state={s2} (want SUSPENDED, not CRASHED)")
    failures += s2 == "CRASHED"

    t0 = time.monotonic()
    r = await provider.exec(handle, "echo back", timeout_s=300)
    print(
        f"step 3    exec rc={r.return_code} err={r.error_type} in {time.monotonic() - t0:.1f} s; state={await state(provider, handle)}"
    )
    failures += r.return_code != 0

    await provider.close(handle)
    await provider.aclose()
    print("RESULT", "PASS" if failures == 0 else f"FAIL ({failures})")
    return failures


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
