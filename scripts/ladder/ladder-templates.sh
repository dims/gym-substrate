#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# What the ladder needs beyond hack/rerun-all.sh: the four burn tags (python:3.12-slim under
# names that give one template per size), their templates with golden snapshots, and the
# saturation provider configs: exec concurrency 1000, idle 3 s before a pause, and the never
# variant; plus the agent-server concurrency overlay.
#   scripts/ladder/ladder-templates.sh
# Environment: WORK (hack/_lib.sh), REGISTRY, ATESPACE, BUCKET_NAME (default ate-snapshots).
# Sizes: burn 1/4Gi, burn-s 500m/2Gi, burn-xs 250m/1Gi, burn-xxs 125m/512Mi; with POOL_CPU 8 and
# POOL_MEMORY 32Gi a worker holds 8, 16, 32 or 64 of them.
set -uo pipefail
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
BUCKET_NAME="${BUCKET_NAME:-ate-snapshots}"
step "burn tags"
SRC="$REGISTRY/python:3.12-slim"
docker image inspect "$SRC" >/dev/null 2>&1 || fail BURN_SOURCE "$SRC is not in the local docker store; run hack/images.sh first"
for t in burn burn-s burn-xs burn-xxs; do
  if ! { docker tag "$SRC" "$REGISTRY/$t:3.12-slim" && docker push -q "$REGISTRY/$t:3.12-slim" >/dev/null; }; then fail BURN_PUSH "$t"; fi
done
echo "pushed 4 burn tags from $SRC"
step "burn templates"
# One agent digest for all of them: the one an existing template (the gate's) already carries.
AGENT_IMAGE="${AGENT_IMAGE:-$(kubectl ate get actor-template -a "$ATESPACE" -o yaml 2>/dev/null | grep -o -m1 "$REGISTRY/sandbox-agent@sha256:[0-9a-f]*")}"
[ -n "$AGENT_IMAGE" ] && echo "agent image $AGENT_IMAGE" || echo "no template with an agent image yet; ko builds one"
for spec in "burn 1 4Gi" "burn-s 500m 2Gi" "burn-xs 250m 1Gi" "burn-xxs 125m 512Mi"; do
  # shellcheck disable=SC2086
  set -- $spec
  KO_DOCKER_REPO="$REGISTRY" BUCKET_NAME="$BUCKET_NAME" WORKLOAD=gym ACTOR_CPU="$2" ACTOR_MEMORY="$3" ATESPACE="$ATESPACE" ${AGENT_IMAGE:+AGENT_IMAGE="$AGENT_IMAGE"} WAIT_GOLDEN=1 \
    bash "$REPO/hack/gym-templates.sh" "$REGISTRY/$1:3.12-slim" > "$LOG_DIR/template-$1.log" 2>&1 || { tail -5 "$LOG_DIR/template-$1.log"; fail TEMPLATE "$1"; }
  echo "template $1 ($2 / $3): $(tail -1 "$LOG_DIR/template-$1.log")"
  [ -n "$AGENT_IMAGE" ] || AGENT_IMAGE=$(kubectl ate get actor-template -a "$ATESPACE" -o yaml 2>/dev/null | grep -o -m1 "$REGISTRY/sandbox-agent@sha256:[0-9a-f]*")
done
step "saturation configs"
[ -s "$RUN_DIR/substrate.yaml" ] || fail CONFIG "no $RUN_DIR/substrate.yaml; hack/gym-checkout.sh writes it"
sed -E -e 's/concurrency: [0-9]+$/concurrency: 1000/' -e 's/idle_before_suspend_s: .*/idle_before_suspend_s: 3.0/' "$RUN_DIR/substrate.yaml" > "$RUN_DIR/substrate-sat.yaml"
sed -E 's/suspend_policy: .*/suspend_policy: never/' "$RUN_DIR/substrate-sat.yaml" > "$RUN_DIR/substrate-never-sat.yaml"
printf 'mini_swe_agent_2:\n  responses_api_agents:\n    mini_swe_agent_2:\n      concurrency: 1000\n' > "$RUN_DIR/ladder-agent.yaml"
echo "configs: $(grep -E 'ateapi_addr|suspend_policy|concurrency|idle_before|timeout_s: 660' "$RUN_DIR/substrate-sat.yaml" | tr -s ' ' | tr '\n' ';')"
step "ladder-templates done"
