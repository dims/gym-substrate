#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Memory round trips through Substrate's counter demo: one actor (created SUSPENDED from the
# template's golden snapshot, resumed by its first request), its in-RAM counter bumped through the
# router, then CYCLES times a suspend (asynchronous, the pause) and a resume by the next request;
# the count must continue from where it left off. Prints per cycle the time to SUSPENDED, the time
# of the resuming request, the count and the worker pod. Ends with RESULT PASS when every cycle
# continued the count.
#   scripts/probes/counter-roundtrip.sh [CYCLES]        (default 5)
# Environment: WORK (hack/_lib.sh), DEMO_ATESPACE and DEMO_TEMPLATE (default ate-demo-counter-microvm,
# counter-microvm: the demo hack/kind-up.sh deploys for the micro-VM class; the gVisor demo is
# ate-demo-counter / counter).
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
CYCLES=${1:-5}; NS="${DEMO_ATESPACE:-ate-demo-counter-microvm}"; TPL="${DEMO_TEMPLATE:-counter-microvm}"
NODE_IP=$(node_ip); [ -n "$NODE_IP" ] || fail NODE_IP "no $RUN_DIR/node-ip"
NAME="roundtrip-$(date -u +%H%M%S)"
actor_state() { kubectl ate get actor "$NAME" -a "$NS" 2>/dev/null | awk 'NR>1 {print $4}'; }
actor_pod() { kubectl ate get actor "$NAME" -a "$NS" 2>/dev/null | awk 'NR>1 {print $5}'; }
wait_state() { local want=$1 t=$2 i; for ((i = 0; i < t; i++)); do [ "$(actor_state)" = "$want" ] && return 0; sleep 1; done; return 1; }
bump() { curl -s -m 300 -X POST -H "ate-target-actor: $NS/$NAME" "http://$NODE_IP:30080/" | grep -o 'preserved memory count: [0-9]*' | awk '{print $4}'; }
fails=0
step "counter round trips: $CYCLES on $NS/$TPL"
t=$SECONDS
kubectl ate create actor "$NAME" -a "$NS" --template "$TPL" >/dev/null || fail CREATE
wait_state ACTOR_STATE_SUSPENDED 300 || fail CREATED "state $(actor_state) after 300 s (a new actor is SUSPENDED on its golden snapshot)"
c0=$((SECONDS - t)); t=$SECONDS; count=$(bump); echo "created in ${c0}s; first request (the first resume) ${count:-?} in $((SECONDS - t))s on $(actor_pod)"
[ "$count" = 1 ] || fails=$((fails + 1))
for ((c = 1; c <= CYCLES; c++)); do
  t=$SECONDS; kubectl ate suspend actor "$NAME" -a "$NS" >/dev/null 2>&1
  wait_state ACTOR_STATE_SUSPENDED 300 || { echo "cycle $c: state $(actor_state) after 300 s"; fails=$((fails + 1)); continue; }
  s=$((SECONDS - t)); t=$SECONDS; got=$(bump); r=$((SECONDS - t))
  want=$((count + 1)); ok=$([ "$got" = "$want" ] && echo ok || echo WRONG)
  echo "cycle $c: suspended in ${s}s, resumed by the request in ${r}s, count $got (want $want) $ok, pod $(actor_pod)"
  [ "$ok" = ok ] || fails=$((fails + 1)); count=$got
done
kubectl ate delete actor "$NAME" -a "$NS" --any-state >/dev/null 2>&1 && echo "deleted $NAME"
echo "RESULT $([ "$fails" -eq 0 ] && echo PASS || echo "FAIL ($fails)")"
[ "$fails" -eq 0 ]
