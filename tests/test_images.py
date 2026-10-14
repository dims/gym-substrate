# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import os
import pathlib
import subprocess

import pytest


ROOT = pathlib.Path(__file__).resolve().parent.parent
INSTANCE = "scikit-learn__scikit-learn-14141"


@pytest.fixture
def image_env(tmp_path):
    work = tmp_path / "work"
    tools = work / "bin"
    tools.mkdir(parents=True)
    scripts = {
        "uname": 'echo "${TEST_ARCH:-aarch64}"',
        "git": 'echo "git $*" >> "$COMMAND_LOG"',
        "docker": """echo "docker $*" >> "$COMMAND_LOG"
case "$1" in
  image) test -f "$WORK/loaded" ;;
  pull) exit 1 ;;
  buildx) echo archive; exit "${BUILD_EXIT:-0}" ;;
  save) echo archive ;;
  load) cat >/dev/null; touch "$WORK/loaded" ;;
  tag|push) exit 0 ;;
  *) exit 1 ;;
esac""",
        "zstd": """if [ "$1" = -d ]; then
  cat "${@: -1}"
else
  while [ "$1" != -o ]; do shift; done
  cat > "$2"
fi""",
    }
    for name, body in scripts.items():
        path = tools / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)
    source = work / "swe-bench-tasks"
    (source / ".git").mkdir(parents=True)
    task = source / "tasks" / INSTANCE
    task.mkdir(parents=True)
    (task / "Dockerfile.arm64").write_text("FROM scratch\n")
    env = {**os.environ, "WORK": str(work), "COMMAND_LOG": str(tmp_path / "commands")}
    env.pop("IMAGE_TARBALLS", None)
    return env


def run_images(env):
    result = subprocess.run(["bash", str(ROOT / "hack/images.sh"), INSTANCE], env=env, capture_output=True, text=True)
    return result, pathlib.Path(env["COMMAND_LOG"]).read_text()


def test_arm64_builds_an_archive_and_uses_the_loader(image_env):
    result, commands = run_images(image_env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "docker buildx build --platform linux/arm64" in commands
    assert "--load" in commands
    assert commands.index("docker save") < commands.index("docker load")
    assert "docker load" in commands and "docker push" in commands
    assert list(pathlib.Path(image_env["WORK"]).rglob("*.tar.zst"))
    (pathlib.Path(image_env["WORK"]) / "loaded").unlink()
    result, commands = run_images(image_env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert commands.count("docker buildx") == 1
    assert commands.count("docker load") == 2


@pytest.mark.parametrize("has_archive", [True, False])
def test_explicit_archives_take_precedence(image_env, tmp_path, has_archive):
    if has_archive:
        (tmp_path / "image.tar.zst").write_text("archive")
    image_env["IMAGE_TARBALLS"] = str(tmp_path)
    result, commands = run_images(image_env)
    assert (result.returncode == 0) == has_archive, result.stdout + result.stderr
    assert ("docker load" in commands) == has_archive
    assert "git " not in commands and "docker buildx" not in commands


def test_amd64_does_not_build_an_arm64_image(image_env):
    image_env["TEST_ARCH"] = "x86_64"
    result, commands = run_images(image_env)
    assert result.returncode != 0
    assert "IMAGE_MISSING" in result.stdout
    assert "git " not in commands and "docker buildx" not in commands


def test_failed_build_does_not_publish_an_archive(image_env):
    image_env["BUILD_EXIT"] = "1"
    result, commands = run_images(image_env)
    assert result.returncode != 0
    assert "docker buildx" in commands
    assert "docker save" not in commands
    assert "docker load" not in commands and "docker push" not in commands
    assert not list(pathlib.Path(image_env["WORK"]).rglob("*.tar.zst"))
