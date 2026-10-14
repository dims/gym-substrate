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

"""Delete actors in an atespace by name or by state.

    ATEAPI_ADDR=localhost:8080 python scripts/delete_actors.py ATESPACE NAME...
    ATEAPI_ADDR=localhost:8080 python scripts/delete_actors.py ATESPACE --state CRASHED --state SUSPENDED
    ATEAPI_ADDR=localhost:8080 python scripts/delete_actors.py ATESPACE --all

Deletes with any_state, so a running, paused or mid-transition actor goes too.
Nothing is deleted without a name, a state or --all. Do not put --all in a
loop: it removes every live sandbox in the atespace, including the ones a run
is using.
"""

import argparse
import asyncio
import os
import sys

from gym_substrate import SubstrateProvider
from gym_substrate._ateapi import ateapi_pb2


def state_name(actor) -> str:
    return ateapi_pb2.ActorState.Name(actor.status.state).removeprefix("ACTOR_STATE_")


def select_actors(actors, names, states, everything):
    if everything:
        return list(actors)
    wanted, wanted_states = set(names), {s.upper() for s in states}
    return [a for a in actors if a.metadata.name in wanted or state_name(a) in wanted_states]


async def list_actors(provider, atespace):
    actors, token = [], ""
    while True:
        page = await provider._control(
            "ListActors",
            ateapi_pb2.ListActorsRequest(
                atespace=atespace, options=ateapi_pb2.ListOptions(page_size=200, page_token=token)
            ),
        )
        actors.extend(page.actors)
        token = page.next_page_token
        if not token:
            return actors


def parse(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("atespace")
    parser.add_argument("names", nargs="*", metavar="NAME")
    parser.add_argument(
        "--state", action="append", default=[], help="actors in this state, such as CRASHED (repeatable)"
    )
    parser.add_argument("--all", action="store_true", help="every actor in the atespace")
    args = parser.parse_args(argv)
    if not (args.names or args.state or args.all):
        parser.error("give actor names, --state, or --all")
    return args


async def main(args) -> None:
    provider = SubstrateProvider(
        connection={
            "atespace": args.atespace,
            "template_namespace": args.atespace,
            "ateapi_addr": os.environ.get("ATEAPI_ADDR", "localhost:8080"),
        }
    )
    actors = await list_actors(provider, args.atespace)
    chosen = select_actors(actors, args.names, args.state, args.all)
    for actor in chosen:
        ref = ateapi_pb2.ObjectRef(atespace=args.atespace, name=actor.metadata.name)
        await provider._control("DeleteActor", ateapi_pb2.DeleteActorRequest(actor=ref, any_state=True))
        print(f"deleted {actor.metadata.name} ({state_name(actor)})")
    await provider.aclose()
    print(f"deleted {len(chosen)} of {len(actors)} actors in {args.atespace}")


if __name__ == "__main__":
    asyncio.run(main(parse(sys.argv[1:])))
