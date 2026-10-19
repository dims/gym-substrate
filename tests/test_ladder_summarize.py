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
import shutil


ROOT = pathlib.Path(__file__).resolve().parent
FIXTURE = ROOT / "fixtures" / "ladder"


def _summarize():
    path = ROOT.parent / "scripts" / "ladder" / "summarize.py"
    spec = importlib.util.spec_from_file_location("summarize", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_one_row_per_arm_in_start_order() -> None:
    rows = _summarize().summarize(FIXTURE)
    assert [r[0] for r in rows] == ["s2-16-never", "s1b-64-never"]
    # Gym arm: the runner's wall and per-task latencies; the host sampler started later, so no peak.
    assert rows[0] == ["s2-16-never", "16 rollouts", "PASS", "78 s", "", "1.1 min", "1.2 min", "0", "0", "", ""]
    # Burn arm: 2 shards x 2 sandboxes x 15 steps; first step = median exec0 of the four sandboxes.
    assert rows[1] == [
        "s1b-64-never",
        "4 x 15 steps",
        "PASS",
        "787 s",
        "467.5 s",
        "20.3 s",
        "482.9 s",
        "0",
        "0",
        "53 G",
        "0",
    ]


def test_failures_count_and_fail_the_arm(tmp_path: pathlib.Path) -> None:
    shutil.copytree(FIXTURE, tmp_path / "ladder")
    d = tmp_path / "ladder"
    with (d / "s1b-64-never-1.tsv").open("a") as f:
        f.write("1\texec14\t20.0\t1\tCRASHED\talive\n")  # a failed exec on a crashed actor
        f.write("1\tSTEP-FAILED\t0.0\t1\tCRASHED\trc=1\n")
    with (d / "s1b-64-never-snaps.txt").open("a") as f:
        f.write(
            "[03:19:00] during-s1b-64-never: actors  3 RUNNING 1 CRASHED  | workers active 2 | restarts 2 |  busy=50%\n"
        )
    with (d / "events.log").open("a") as f:
        f.write("2026-10-19T03:19:12Z ladder: start s2-16-pause (run_arm /x/substrate-sat.yaml n=16 think=2 box=0)\n")
        f.write("2026-10-19T04:49:12Z ladder: end s2-16-pause rc=124 (124 = time box)\n")
    rows = {r[0]: r for r in _summarize().summarize(d)}
    burn = rows["s1b-64-never"]
    assert burn[2] == "FAIL"
    assert burn[7:9] == ["1", "2"]  # one rc != 0 exec; one crashed actor plus one STEP-FAILED row
    assert burn[10] == "1"  # restarts 1 -> 2 during the arm
    assert rows["s2-16-pause"][2] == "TIMEBOX"


def test_cli_prints_a_table(capsys) -> None:
    assert _summarize().main([str(FIXTURE), "--label", "box", "--no-header"]) == 0
    out = capsys.readouterr().out.splitlines()
    assert len(out) == 2 and out[0].startswith("| box | s2-16-never |")
