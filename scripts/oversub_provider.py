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

"""Oversubscription experiment: more sandboxes than workers, each stepping with gaps.

    ATEAPI_ADDR=localhost:8080 ATENET_ADDR=localhost:8000 IMAGE=python:3.12-slim \
      python scripts/oversub_provider.py [N_SANDBOXES] [STEPS] [GAP_S] [POLICY]

Every sandbox runs STEPS execs with GAP_S of idle time between them (standing in
for the policy model thinking). With pause_after_exec, an idle sandbox holds no
worker, so N_SANDBOXES can exceed the WorkerPool size. Prints per-step latency
and the actor state seen after each exec, plus a summary. The image must have a
template (hack/gym-templates.sh).
"""

import asyncio
import os
import statistics
import sys
import time

from nemo_gym.sandbox.providers.base import SandboxSpec

from gym_substrate import SubstrateProvider
from gym_substrate._ateapi import ateapi_pb2


N = int(sys.argv[1]) if len(sys.argv) > 1 else 6
STEPS = int(sys.argv[2]) if len(sys.argv) > 2 else 3
GAP_S = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
POLICY = sys.argv[4] if len(sys.argv) > 4 else "pause_after_exec"
IMAGE = os.environ.get("IMAGE", "python:3.12-slim")
ATESPACE = os.environ.get("ATESPACE", "nemo-gym")


async def one_sandbox(provider, idx: int, rows: list) -> None:
    t0 = time.monotonic()
    handle = await provider.create(SandboxSpec(image=IMAGE))
    rows.append((idx, "create", time.monotonic() - t0, 0, ""))
    for step in range(STEPS):
        await asyncio.sleep(GAP_S)
        t0 = time.monotonic()
        result = await provider.exec(handle, f"echo {idx}-{step} >> /tmp/steps; wc -l < /tmp/steps")
        actor = await provider._control("GetActor", ateapi_pb2.GetActorRequest(actor=handle.raw.object_ref))
        rows.append(
            (
                idx,
                f"exec{step}",
                time.monotonic() - t0,
                result.return_code,
                ateapi_pb2.ActorState.Name(actor.status.state),
            )
        )
        # /tmp/steps must survive pause/resume: the count equals the step number.
        if (result.stdout or "").strip() != str(step + 1):
            rows.append((idx, "STATE-LOST", 0.0, result.return_code, (result.stdout or "").strip()))
    t0 = time.monotonic()
    await provider.close(handle)
    rows.append((idx, "close", time.monotonic() - t0, 0, ""))


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
    rows: list = []
    wall0 = time.monotonic()
    results = await asyncio.gather(*(one_sandbox(provider, i, rows) for i in range(N)), return_exceptions=True)
    wall = time.monotonic() - wall0
    await provider.aclose()

    for row in sorted(rows):
        print("%3d %-10s %7.1fs rc=%s %s" % row)
    errors = [r for r in results if isinstance(r, Exception)]
    for e in errors:
        print("ERROR", repr(e)[:300])
    lost = [r for r in rows if r[1] == "STATE-LOST"]
    for phase in ("create", "close") + tuple(f"exec{s}" for s in range(STEPS)):
        lat = [r[2] for r in rows if r[1] == phase]
        if lat:
            print(f"{phase:8s} n={len(lat):2d} median={statistics.median(lat):6.1f}s max={max(lat):6.1f}s")
    print(
        f"policy={POLICY} sandboxes={N} steps={STEPS} gap={GAP_S}s wall={wall:.1f}s errors={len(errors)} state_lost={len(lost)}"
    )
    print("RESULT", "PASS" if not errors and not lost else "FAIL")
    return 1 if errors or lost else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
