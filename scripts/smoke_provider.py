# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Live smoke for the Substrate sandbox provider against a cluster.

    ATEAPI_ADDR=localhost:8080 ATENET_ADDR=localhost:8000 ATESPACE=nemo-gym \
      python scripts/smoke_provider.py [IMAGE] [never|after_exec|pause_after_exec]

create -> wait past the idle debounce and assert the policy's parked state -> exec (a resume)
-> wait and assert again -> exec (a resume) -> exec -> timeout -> status -> download -> close.
"""

import asyncio
import logging
import os
import pathlib
import sys
import tempfile
import time

from nemo_gym.sandbox.providers.base import SandboxSpec

from gym_substrate import SubstrateProvider
from gym_substrate._ateapi import ateapi_pb2


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

IMAGE = sys.argv[1] if len(sys.argv) > 1 else "python:3.12-slim"
POLICY = sys.argv[2] if len(sys.argv) > 2 else "pause_after_exec"
ATESPACE = os.environ.get("ATESPACE", "nemo-gym")
# idle_before_suspend_s in configs/substrate.yaml is 1 s; wait past it before reading the state.
PARK_WAIT_S = 1.5


def is_parked(actor, policy: str) -> bool:
    if actor.status.state != ateapi_pb2.ActorState.ACTOR_STATE_SUSPENDED:
        return False
    latest = max(actor.status.snapshots, key=lambda snapshot: snapshot.generation, default=None)
    if latest is None:
        return False
    if policy == "pause_after_exec":
        return bool(latest.locality) and not latest.HasField("durable_snapshot")
    return (
        latest.HasField("durable_snapshot")
        and latest.durable_snapshot.status == ateapi_pb2.SNAPSHOT_STORAGE_STATUS_COMPLETED
    )


async def check_parked(provider, handle, label: str) -> bool:
    await asyncio.sleep(PARK_WAIT_S)
    actor = await provider._control("GetActor", ateapi_pb2.GetActorRequest(actor=handle.raw.object_ref))
    state = ateapi_pb2.ActorState.Name(actor.status.state)
    parked = is_parked(actor, POLICY)
    print(f"parked    {PARK_WAIT_S:6.1f}s  state={state} snapshot_matches_policy={parked} ({label})")
    return parked


async def actor_state(provider, handle) -> str:
    actor = await provider._control("GetActor", ateapi_pb2.GetActorRequest(actor=handle.raw.object_ref))
    return ateapi_pb2.ActorState.Name(actor.status.state)


async def main() -> int:
    provider = SubstrateProvider(
        connection={
            "atespace": ATESPACE,
            "template_namespace": ATESPACE,
            "ateapi_addr": os.environ.get("ATEAPI_ADDR", "localhost:8080"),
            "atenet_addr": os.environ.get("ATENET_ADDR", "localhost:8000"),
        },
        create={"suspend_policy": POLICY, "ready_timeout_s": 900},
    )
    failures = 0

    t0 = time.monotonic()
    handle = await provider.create(SandboxSpec(image=IMAGE, files={"/work/seed.txt": "seed\n"}))
    print(
        f"create    {time.monotonic() - t0:6.1f}s  id={handle.sandbox_id}  state={await actor_state(provider, handle)}"
    )
    if POLICY != "never":
        # The provider parks a new sandbox too, so the first exec is a resume.
        failures += not await check_parked(provider, handle, "first exec is a resume")

    commands = [
        "echo hello; python3 --version; cat /work/seed.txt; echo $FOO",
        "echo $$ > /work/pid; sleep 1; echo step2",
        "cat /work/pid; env | grep -c .",
    ]
    for i, cmd in enumerate(commands):
        t0 = time.monotonic()
        result = await provider.exec(handle, cmd, cwd="/work", env={"FOO": "bar"})
        state = await actor_state(provider, handle)
        print(
            f"exec{i}     {time.monotonic() - t0:6.1f}s  rc={result.return_code} err={result.error_type} "
            f"state={state} stdout={(result.stdout or '').strip()!r} stderr={(result.stderr or '').strip()!r}"
        )
        failures += result.return_code != 0
        if i == 0 and POLICY != "never":
            failures += not await check_parked(provider, handle, "next exec is the resume")

    result = await provider.exec(handle, "sleep 5", timeout_s=1)
    print(f"timeout            rc={result.return_code} err={result.error_type}")
    failures += not (result.return_code == 125 and result.error_type == "timeout")

    print(f"status             {await provider.status(handle)}")

    target = pathlib.Path(tempfile.mkdtemp()) / "pid"
    await provider.download_file(handle, "/work/pid", target)
    print(f"download           /work/pid={target.read_text().strip()!r}")

    t0 = time.monotonic()
    await provider.close(handle)
    print(f"close     {time.monotonic() - t0:6.1f}s  status={await provider.status(handle)}")
    await provider.aclose()
    print("RESULT", "PASS" if failures == 0 else f"FAIL ({failures})")
    return failures


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
