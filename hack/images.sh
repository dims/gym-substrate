#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Put the task images into the kind registry under the names the Gym agent will ask for after
# the rewrite file this script writes, and record them for hack/gym-templates.sh.
#   hack/images.sh INSTANCE_ID|IMAGE...
# An argument with ':' or '/' is an image; anything else is a SWE-bench instance id and maps to
# docker.io/swebench/sweb.eval.<arch>.<id with __ -> _1776_>:latest, with the x86_64 names
# turned into arm64 ones on an arm64 host. An image that is not public is taken from
# IMAGE_TARBALLS/*.tar.zst when a loaded tag matches. Without IMAGE_TARBALLS,
# missing arm64 task images are built into archives from the pinned task recipe.
set -uo pipefail
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/_lib.sh"
SW=$(swebench_arch)
images=()
for a in "$@"; do
  case "$a" in
    */*|*:*) images+=("$a") ;;
    *) id=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]'); images+=("docker.io/swebench/sweb.eval.$SW.${id//__/_1776_}:latest") ;;
  esac
done
have() { docker image inspect "$1" >/dev/null 2>&1; }
loaded=0
load_tarballs() {
  local tarballs=() archive t
  if [ -z "${IMAGE_TARBALLS:-}" ] && [ "$SW" = arm64 ]; then
    archive=$(bash "$REPO/hack/build-arm64-image.sh" "$1") || fail IMAGE_BUILD "$1"
    tarballs=("$archive")
  else
    [ "$loaded" = 0 ] || return 0; loaded=1
    [ -n "${IMAGE_TARBALLS:-}" ] || return 0
    tarballs=("$IMAGE_TARBALLS"/*.tar.zst)
  fi
  for t in "${tarballs[@]}"; do
    [ -e "$t" ] || continue
    echo "loading $(basename "$t")"
    zstd -d -c "$t" | docker load >> "$LOG_DIR/docker-load.log" 2>&1 || fail IMAGE_LOAD "$t"
  done
}
: > "$RUN_DIR/images.txt"
for img in "${images[@]}"; do
  src=${img/sweb.eval.x86_64./sweb.eval.$SW.}
  name=${src#docker.io/}
  target="$REGISTRY/${name#library/}"
  base=${name##*/}
  candidates=("$target" "$src" "$name" "$base" "${base//_1776_/__}")
  found=""
  for c in "${candidates[@]}"; do have "$c" && { found=$c; break; }; done
  if [ -z "$found" ] && docker pull -q "$src" >/dev/null 2>&1; then found=$src; fi
  if [ -z "$found" ]; then
    load_tarballs "$src"
    for c in "${candidates[@]}"; do have "$c" && { found=$c; break; }; done
  fi
  [ -n "$found" ] || fail IMAGE_MISSING "$src is not public and no tarball under ${IMAGE_TARBALLS:-IMAGE_TARBALLS} provides it"
  docker tag "$found" "$target" || fail IMAGE_TAG "$target"
  docker push -q "$target" >/dev/null || fail IMAGE_PUSH "$target"
  echo "pushed $target (from $found)"
  echo "$target" >> "$RUN_DIR/images.txt"
done
REW="$RUN_DIR/image-rewrites.yaml"
printf 'mini_swe_agent_2:\n  responses_api_agents:\n    mini_swe_agent_2:\n      sandbox_spec:\n        image_rewrites:\n          - from: docker.io/swebench/sweb.eval.x86_64.\n            to: %s/swebench/sweb.eval.%s.\n' "$REGISTRY" "$SW" > "$REW"
echo "rewrites: $REW (sweb.eval.$SW)"
echo "images done: $(wc -l < "$RUN_DIR/images.txt" | tr -d ' ')"
