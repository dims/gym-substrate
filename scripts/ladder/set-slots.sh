#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Scale the gym pools so the install offers SLOTS one-core slots: SLOTS / POOL_CPU workers spread over
# the pools hack/kind-up.sh rendered, then wait until that many are ACTIVE and no other gym worker is
# left. The ladder's SLOTS pin only scales N; this changes the capacity. Run it with no actor in the
# atespace.
#   scripts/ladder/set-slots.sh SLOTS
# Environment: WORK (hack/_lib.sh), POOL_CPU (default 8).
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
SLOTS=${1:?slots}; POOL_CPU="${POOL_CPU:-8}"; EV="$RUN_DIR/events.log"
[ $((SLOTS % POOL_CPU)) -eq 0 ] || fail SLOTS "$SLOTS is not a multiple of POOL_CPU $POOL_CPU"
left=$(actors_left); [ "$left" -eq 0 ] || fail ACTORS "$left actors in $ATESPACE"
WANT=$((SLOTS / POOL_CPU)); pools=$(kubectl get workerpool -n ate-demo-sandbox -l workload=gym -o jsonpath='{.items[*].metadata.name}'); n=$(echo "$pools" | wc -w | tr -d ' ')
[ "$n" -gt 0 ] || fail POOLS "no gym pools"
i=0; for p in $pools; do r=$(( WANT / n + (i < WANT % n ? 1 : 0) )); kubectl scale workerpool -n ate-demo-sandbox "$p" --replicas="$r" >/dev/null || fail SCALE "$p"; i=$((i + 1)); done
echo "$(date -u +%FT%TZ) set-slots: $SLOTS slots = $WANT workers over $n pools" | tee -a "$EV"
gym_workers() { kubectl ate get workers 2>/dev/null | awk '$2 ~ /^gym-workerpool/'; }
settled() { [ "$(gym_workers | awk '$3=="WORKER_STATE_ACTIVE"' | wc -l | tr -d ' ')" -eq "$WANT" ] && [ "$(gym_workers | wc -l | tr -d ' ')" -eq "$WANT" ]; }
wait_for 900 "gym workers to settle at $WANT" settled || { gym_workers | awk '{print $3}' | sort | uniq -c; fail WORKERS; }
echo "$(date -u +%FT%TZ) set-slots: $WANT gym workers ACTIVE" | tee -a "$EV"
