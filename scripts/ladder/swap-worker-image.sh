#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Put another worker image under the gym pools, for an A/B of two worker builds: the pools
# hack/kind-up.sh rendered are deleted and applied again with IMAGE, then every worker is
# waited for. Run it at an arm boundary with no actor in the atespace.
#   scripts/ladder/swap-worker-image.sh IMAGE
# Environment: WORK (hack/_lib.sh).
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
IMAGE=${1:?worker image}; POOLS="$RUN_DIR/gym-workerpools.yaml"; EV="$RUN_DIR/events.log"
[ -s "$POOLS" ] || fail POOLS "no $POOLS; hack/kind-up.sh writes it"
left=$(actors_left); [ "$left" -eq 0 ] || fail ACTORS "$left actors in $ATESPACE; swap at an arm boundary"
WANT=$(grep -c '^kind: WorkerPool' "$POOLS"); WANT=$(( WANT * $(awk '/^  replicas:/ {print $2; exit}' "$POOLS") ))
echo "$(date -u +%FT%TZ) swap-worker-image: $IMAGE" | tee -a "$EV"
kubectl delete -f "$POOLS" --wait=true >/dev/null || fail DELETE
sed -E "s#^  workerImage: .*#  workerImage: $IMAGE#" "$POOLS" > "$POOLS.tmp" && mv "$POOLS.tmp" "$POOLS"
# The old pods and their worker records linger after the delete, so wait until every gym worker pod
# runs IMAGE and WANT of them are ACTIVE, not for the first ACTIVE count.
gym_pods() { kubectl -n ate-demo-sandbox get pods -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.spec.containers[0].image}{"\n"}{end}' 2>/dev/null | awk '$1 ~ /^gym-workerpool/'; }
old_pods_gone() { [ "$(gym_pods | wc -l | tr -d ' ')" -eq 0 ]; }
wait_for 600 "the old gym worker pods" old_pods_gone || { kubectl get pods -n ate-demo-sandbox; fail OLD_WORKERS; }
kubectl apply -f "$POOLS" >/dev/null || fail APPLY
active_workers() { [ "$(kubectl ate get workers 2>/dev/null | awk '$2 ~ /^gym-workerpool/ && $3=="WORKER_STATE_ACTIVE"' | wc -l | tr -d ' ')" -ge "$WANT" ] && [ "$(gym_pods | awk -v img="$IMAGE" '$2 == "Running" && $3 == img' | wc -l | tr -d ' ')" -ge "$WANT" ]; }
wait_for 900 "gym workers" active_workers || { kubectl get pods -n ate-demo-sandbox; fail WORKERS; }
echo "$(date -u +%FT%TZ) swap-worker-image: $WANT workers ACTIVE on $(kubectl get workerpool -n ate-demo-sandbox -l workload=gym -o jsonpath='{.items[0].spec.workerImage}')" | tee -a "$EV"
