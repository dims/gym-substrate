#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Start a ladder chain, detached, only when every gym worker is ACTIVE and the atespace is empty.
#   scripts/ladder/launch-guard.sh MODE...
# Environment: WANT_WORKERS (default: the replicas of the gym pools).
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
LD="$(cd "$(dirname "$0")" && pwd)"
WANT=${WANT_WORKERS:-$(kubectl get workerpool -n ate-demo-sandbox -l workload=gym -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}')}
n=$(kubectl ate get workers 2>/dev/null | awk '$2 ~ /^gym-workerpool/ && $3=="WORKER_STATE_ACTIVE"' | wc -l | tr -d ' '); a=$(actors_left)
if [ "$WANT" -eq 0 ] || [ "$n" -lt "$WANT" ] || [ "$a" -ne 0 ]; then
  echo "REFUSED: $n of $WANT gym workers ACTIVE, $a actors in $ATESPACE"; kubectl ate get workers 2>/dev/null | awk 'NR>1 {print $3}' | sort | uniq -c; exit 1
fi
rm -f "$RUN_DIR/PAUSE" "$RUN_DIR/STOP"
setsid nohup bash "$LD/ladder-chain.sh" "$@" > "$LOG_DIR/ladder-chain-$(date -u +%Y%m%dT%H%MZ).log" 2>&1 < /dev/null &
echo "$(date -u +%FT%TZ) chain: launched pid $! modes: $* ($n ACTIVE workers, $a actors)" | tee -a "$RUN_DIR/events.log"
