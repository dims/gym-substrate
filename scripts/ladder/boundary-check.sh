#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Between a control-plane change and the next arm: every gym worker ACTIVE, the sandbox assets
# prewarmed on each atelet, restart counters, one provider smoke through the NodePorts, no actor
# left. Exit 1 when the workers or the smoke fail.
#   scripts/ladder/boundary-check.sh
# Environment: WORK (hack/_lib.sh), GYM_DIR (default WORK/gym), WANT_WORKERS (default: the
# replicas of the gym pools).
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
GYM_DIR="${GYM_DIR:-$WORK/gym}"; EV="$RUN_DIR/events.log"; ev() { echo "$(date -u +%FT%TZ) boundary-check: $*" | tee -a "$EV"; }
NODE_IP=$(node_ip); [ -n "$NODE_IP" ] || fail NODE_IP "no $RUN_DIR/node-ip"
WANT=${WANT_WORKERS:-$(kubectl get workerpool -n ate-demo-sandbox -l workload=gym -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}')}
n=0; for i in $(seq 1 60); do n=$(kubectl ate get workers 2>/dev/null | awk '$2 ~ /^gym-workerpool/ && $3=="WORKER_STATE_ACTIVE"' | wc -l | tr -d ' '); [ "$n" -ge "$WANT" ] && break; sleep 5; done
ev "gym workers ACTIVE $n of $WANT after $((i * 5)) s"
pods=$(kubectl -n ate-system get pods --no-headers | awk '/atelet/ {print $1}')
for p in $pods; do
  echo "$p $(kubectl -n ate-system get pod "$p" -o jsonpath='{.spec.nodeName} restarts={.status.containerStatuses[*].restartCount}') $(kubectl -n ate-system logs "$p" -c atelet 2>/dev/null | grep -E 'Sandbox assets prewarmed|prewarm failed' | tail -1 | grep -o -E 'version=[^ ]+|assets=[0-9]+|prewarm failed' | tr '\n' ' ')"
done
kubectl -n ate-system get pods --no-headers | awk '$4>0 {print "restart counter:", $1, $4}'
cd "$GYM_DIR" || fail GYM_DIR "$GYM_DIR"
# shellcheck disable=SC1091
source .venv/bin/activate
ATEAPI_ADDR="$NODE_IP:30443" ATENET_ADDR="$NODE_IP:30080" ATESPACE="$ATESPACE" python "$REPO/scripts/smoke_provider.py" "$REGISTRY/python:3.12-slim" pause_after_exec > "$LOG_DIR/smoke-boundary.log" 2>&1; rc=$?
ev "smoke rc=$rc $(grep -E '^(RESULT|parked|close)' "$LOG_DIR/smoke-boundary.log" | tr '\n' ' ')"
[ $rc -eq 0 ] || grep -v -E "^(INFO|DEBUG)" "$LOG_DIR/smoke-boundary.log" | tail -15
left=$(actors_left); echo "actors left: $left"
[ "$n" -ge "$WANT" ] && [ $rc -eq 0 ] && [ "$left" -eq 0 ]
