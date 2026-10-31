# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import importlib.util
import pathlib


def _load():
    path = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "ladder" / "restore_phases.py"
    spec = importlib.util.spec_from_file_location("restore_phases", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_restore_phases_reads_json_and_text_lines() -> None:
    rp = _load()
    json_line = (
        '{"time":"2026-10-19T13:23:54Z","msg":"Actor restore phases","id":"bd80efa5-1",'
        '"vm_restore":220000000,"reseed":6500000000,"wakeup_probe":10000000,"total":6610000000}'
    )
    text_line = (
        'time=2026-10-19T13:29:24Z level=INFO msg="Actor restore phases" id=05a5448e-2 '
        "vm_restore=1.2s reseed=1m2.5s wakeup_probe=90ms total=1m4s"
    )
    records = [rp.parse(line) for line in (json_line, text_line, "", 'msg="Actor boot phases" total=1s')]
    records = [r for r in records if r]

    assert [r["reseed"] for r in records] == [6.5, 62.5]
    assert records[1]["total"] == 64.0 and records[0]["vm_restore"] == 0.22
    lines = rp.summarize(records)
    assert lines[0] == "restores: 2"
    assert "reseed over 5s: 2 of 2" in lines
    assert lines[-1].startswith("slow reseed 6.50s at 2026-10-19T13:23:54 actor bd80efa5")
