#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build a SWE-bench task archive; print its path for images.sh's tarball loader.
set -euo pipefail
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/_lib.sh"
IMAGE="${1:?task image}"
REF="${IMAGE#docker.io/}"
case "$REF" in
  swebench/sweb.eval.arm64.*:latest) ;;
  *) echo "no arm64 task recipe for $IMAGE" >&2; exit 1 ;;
esac
INSTANCE="${REF#swebench/sweb.eval.arm64.}"; INSTANCE="${INSTANCE%:latest}"; INSTANCE="${INSTANCE//_1776_/__}"
# https://github.com/SWE-bench/swe-bench-tasks/pull/24
TASKS_COMMIT=638367daa6e8795ab4fcd340613bf4ac87b910b2
ARCHIVE="$WORK/images-arm64/$TASKS_COMMIT/$INSTANCE.tar.zst"
if [ ! -s "$ARCHIVE" ]; then
  SOURCE="$WORK/swe-bench-tasks"
  if [ ! -d "$SOURCE/.git" ]; then
    git clone -q --no-checkout https://github.com/dims/swe-bench-tasks.git "$SOURCE"
  fi
  git -C "$SOURCE" fetch -q --depth=1 origin "$TASKS_COMMIT"
  git -C "$SOURCE" checkout -q --detach "$TASKS_COMMIT"
  TASK="$SOURCE/tasks/$INSTANCE"
  [ -f "$TASK/Dockerfile.arm64" ] || { echo "no Dockerfile.arm64 for $INSTANCE at $TASKS_COMMIT" >&2; exit 1; }
  mkdir -p "$(dirname "$ARCHIVE")"
  TMP_ARCHIVE=$(mktemp "$ARCHIVE.XXXXXX")
  trap 'rm -f "$TMP_ARCHIVE"' EXIT
  echo "building $IMAGE from swe-bench-tasks $TASKS_COMMIT" >&2
  docker buildx build --platform linux/arm64 -f "$TASK/Dockerfile.arm64" -t "$IMAGE" \
    --output type=docker,dest=- "$TASK" | zstd -T0 -q -f -o "$TMP_ARCHIVE"
  mv "$TMP_ARCHIVE" "$ARCHIVE"
fi
printf '%s\n' "$ARCHIVE"
