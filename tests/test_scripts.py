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

import importlib.util
import pathlib

import pytest

from gym_substrate._ateapi import ateapi_pb2


def _load(name: str):
    path = pathlib.Path(__file__).resolve().parent.parent / "scripts" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _actor(name: str, state: int):
    return ateapi_pb2.Actor(
        metadata=ateapi_pb2.ResourceMetadata(name=name), status=ateapi_pb2.ActorStatus(state=state)
    )


def test_delete_actors_selects_by_name_or_state_only() -> None:
    delete_actors = _load("delete_actors")
    actors = [
        _actor("gym-a", ateapi_pb2.ActorState.ACTOR_STATE_RUNNING),
        _actor("gym-b", ateapi_pb2.ActorState.ACTOR_STATE_CRASHED),
        _actor("gym-c", ateapi_pb2.ActorState.ACTOR_STATE_PAUSED),
    ]
    names = lambda chosen: [a.metadata.name for a in chosen]  # noqa: E731

    assert names(delete_actors.select_actors(actors, ["gym-a"], [], False)) == ["gym-a"]
    assert names(delete_actors.select_actors(actors, [], ["crashed"], False)) == ["gym-b"]
    assert names(delete_actors.select_actors(actors, [], [], False)) == []
    assert names(delete_actors.select_actors(actors, [], [], True)) == ["gym-a", "gym-b", "gym-c"]


def test_delete_actors_refuses_an_unscoped_call() -> None:
    delete_actors = _load("delete_actors")
    with pytest.raises(SystemExit):
        delete_actors.parse(["nemo-gym"])
    assert delete_actors.parse(["nemo-gym", "--state", "CRASHED"]).state == ["CRASHED"]
