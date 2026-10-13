#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# From a prepared host to a passing gate in one pass, each step gated on its evidence line.
#   hack/rerun-all.sh [--wipe | --wipe-only]
# --wipe first stops the Gym servers, Ray, the replay policy and port-forwards, deletes the kind
# cluster and its registry, and removes WORK/gym and WORK/run. Nothing else is removed.
# --wipe-only does that and stops.
# Environment: what the step scripts take, plus GATE_INSTANCE (default
# scikit-learn__scikit-learn-14141) and EXTRA_IMAGES (more images to push and template).
set -uo pipefail
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/_lib.sh"
GATE_INSTANCE="${GATE_INSTANCE:-scikit-learn__scikit-learn-14141}"
TS=$(date -u +%Y%m%dT%H%MZ)
exec > >(tee -a "$LOG_DIR/rerun-$TS.log") 2>&1
need() { grep -q -E -- "$2" "$1" || fail STEP "no '$2' in $1"; }
run() { # run NAME EVIDENCE COMMAND...
  local name=$1 evidence=$2 log; shift 2; log="$LOG_DIR/$name.log"
  step "$name"; "$@" 2>&1 | tee "$log"; need "$log" "$evidence"
}

if [ "${1:-}" = "--wipe" ] || [ "${1:-}" = "--wipe-only" ]; then
  step "wipe"
  pkill -f "[g]ym env start"; pkill -f "[g]ym eval run"; pkill -f "[r]eplay_policy.py"; pkill -f "[k]ubectl.*port-forward"; sleep 3
  [ -x "$WORK/gym/.venv/bin/ray" ] && "$WORK/gym/.venv/bin/ray" stop --force >/dev/null 2>&1
  pkill -9 -f "[r]ay/core|[r]ay/dashboard|[r]ay-dashboard|[g]ym env start|[r]eplay_policy.py"; sleep 1
  echo "left: gym=$(pgrep -fc '[g]ym (env|eval)') ray=$(pgrep -fc '[r]ay/core|[r]ay/dashboard|[r]ay-dashboard') replay=$(pgrep -fc '[r]eplay_policy')"
  if kind get clusters 2>/dev/null | grep -qx kind; then
    S="${SUBSTRATE_DIR:-$WORK/substrate}"
    if [ -x "$S/hack/delete-kind-cluster.sh" ]; then (cd "$S" && hack/delete-kind-cluster.sh) >/dev/null 2>&1; else kind delete cluster >/dev/null 2>&1; fi
  fi
  docker rm -f kind-registry >/dev/null 2>&1
  rm -rf "$WORK/gym" "$WORK/run"; mkdir -p "$RUN_DIR"
  echo "clusters: [$(kind get clusters 2>/dev/null | tr '\n' ' ')] kind containers: $(docker ps -a --format '{{.Names}}' | grep -c -E '^kind')"
  [ "${1:-}" = "--wipe-only" ] && { step "WIPE_DONE"; exit 0; }
fi

step "host-check"
bash "$REPO/hack/host-check.sh" 2>&1 | tee "$LOG_DIR/host-check.log"; need "$LOG_DIR/host-check.log" "^host-check ok"
run kind-up "^== .* kind-up done" bash "$REPO/hack/kind-up.sh"
# shellcheck disable=SC2086
run images "^images done: [1-9]" bash "$REPO/hack/images.sh" "$GATE_INSTANCE" python:3.12-slim ${EXTRA_IMAGES:-}
step "templates"
TASK_IMAGES=$(grep -v '/python:3.12-slim$' "$RUN_DIR/images.txt"); SMOKE_IMAGE=$(grep '/python:3.12-slim$' "$RUN_DIR/images.txt")
# shellcheck disable=SC2086
KO_DOCKER_REPO="$REGISTRY" BUCKET_NAME="${BUCKET_NAME:-ate-snapshots}" WORKLOAD=gym ACTOR_CPU=1 ACTOR_MEMORY=4Gi WAIT_GOLDEN=1 ATESPACE="$ATESPACE" bash "$REPO/hack/gym-templates.sh" $TASK_IMAGES 2>&1 | tee "$LOG_DIR/templates-task.log"
need "$LOG_DIR/templates-task.log" "^all templates have a golden"
KO_DOCKER_REPO="$REGISTRY" BUCKET_NAME="${BUCKET_NAME:-ate-snapshots}" WORKLOAD=gym ACTOR_CPU=1 ACTOR_MEMORY=1Gi WAIT_GOLDEN=1 ATESPACE="$ATESPACE" bash "$REPO/hack/gym-templates.sh" "$SMOKE_IMAGE" 2>&1 | tee "$LOG_DIR/templates-smoke.log"
need "$LOG_DIR/templates-smoke.log" "^all templates have a golden"
run gym-checkout "^== .* gym-checkout done" bash "$REPO/hack/gym-checkout.sh"
run gate "^GATE PASS" bash "$REPO/hack/gate.sh" "gate-$TS"
step "RERUN_DONE"
