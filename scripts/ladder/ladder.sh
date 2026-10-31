#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The saturation ladder: one mode per invocation, so a stop rule never skips the next stage.
#   scripts/ladder/ladder.sh MODE
# N scales with SLOTS, the one-core slots of the gym pools (ACTIVE gym workers x POOL_CPU);
# arm names carry N. Modes:
#   s2a      Gym N never, then N pause (think 2 s)      s2never, s2pause: one of the two
#   s1b4x    burn-xs 4 x N running: the restore wave under full load
#   light    burn-xxs 8 x N resident, desynchronized: 3 creates per second, no barrier, 40 x 3 s / 30 s
#   s2b      Gym 2 x N pause (think 60 s) to completion
#   paced    burn-xs 4 x N with the start barrier
#   s4       burn N, one core and a HOLDER_GIB holder each: CPU and memory at the ceiling
#   s2c      Gym 2 x N never (think 2 s)
#   s2d      Gym 4 x N pause (think 60 s), time-boxed 90 min
#   s2e      Gym 6 x N pause (think 60 s), time-boxed 2 h
#   s2f      Gym 8 x N pause (think 60 s), time-boxed 2 h
#   s2g      Gym 8 x N pause (think 120 s), time-boxed 2 h
#   s2h      Gym 8 x N never (think 60 s), time-boxed 2 h
#   soak     3 x (N pause, N never), named soak-<HHMM>-<i>-N-{pause,never} with the ladder's UTC start
# Environment: WORK (hack/_lib.sh), GYM_DIR (default WORK/gym), SLOTS (default ACTIVE gym workers
# x POOL_CPU, POOL_CPU default 8), HOLDER_GIB (default 3.0), GATE_INSTANCE (the row the Gym arms
# repeat, default scikit-learn__scikit-learn-14141), PROM_URL (a Prometheus to dump ate_* series
# from after each arm; default the install's Prometheus on NodePort 30090, skipped when it does not
# answer). Needs the templates and configs of ladder-templates.sh.
# Stop rules, checked every 15 s inside an arm and once after it: CRASHED actors above 1 % of N;
# any ate-system restart; a node not Ready for over STOP_NOTREADY_S (60); host memory used above
# STOP_MEM_USED_GIB (default 90 % of the total); free space under docker's data root below
# STOP_DISK_FREE_GB (default 10 % of that filesystem). A breach ends the arm: its processes are
# killed and the rule is logged.
# After each arm: the actor list, the api-server log and the previous log of every restarted gym
# worker go to the ladder dir, and on the microvm class the restore phases of the arm.
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
MODE=${1:-}; [ -n "$MODE" ] || { echo "usage: ladder.sh MODE"; exit 2; }
GYM_DIR="${GYM_DIR:-$WORK/gym}"; LD="$(cd "$(dirname "$0")" && pwd)"
STAMP=$(date -u +%H%M); OUT="$RUN_DIR/ladder"; mkdir -p "$OUT"
EV="$RUN_DIR/events.log"; ev() { echo "$(date -u +%FT%TZ) ladder: $*" | tee -a "$EV"; }
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)"
NODE_IP=$(node_ip); [ -n "$NODE_IP" ] || fail NODE_IP "no $RUN_DIR/node-ip; run hack/kind-up.sh first"
export ATEAPI_ADDR="$NODE_IP:30443" ATENET_ADDR="$NODE_IP:30080" EXEC_CONCURRENCY="${EXEC_CONCURRENCY:-8192}" READY_TIMEOUT_S="${READY_TIMEOUT_S:-1800}" ATESPACE
PROM_URL="${PROM_URL:-http://$NODE_IP:30090}"
active_gym_workers() { kubectl ate get workers 2>/dev/null | awk '$2 ~ /^gym-workerpool/ && $3=="WORKER_STATE_ACTIVE"' | wc -l | tr -d ' '; }
restarts() { kubectl -n ate-system get pods --no-headers 2>/dev/null | awk '{s+=$4} END{print s+0}'; }
SLOTS="${SLOTS:-$(( $(active_gym_workers) * ${POOL_CPU:-8} ))}"
{ [ "$SLOTS" -gt 0 ] && [ $((SLOTS % 8)) -eq 0 ]; } || fail SLOTS "SLOTS=$SLOTS must be a positive multiple of 8"
HOLDER_GIB="${HOLDER_GIB:-3.0}"
SAT="$RUN_DIR/substrate-sat.yaml"; NEVER="$RUN_DIR/substrate-never-sat.yaml"; AGENT_CFG="$RUN_DIR/ladder-agent.yaml"
ROW="$RUN_DIR/${GATE_INSTANCE:-scikit-learn__scikit-learn-14141}.jsonl"
{ [ -s "$SAT" ] && [ -s "$NEVER" ] && [ -s "$AGENT_CFG" ]; } || fail CONFIGS "run scripts/ladder/ladder-templates.sh first"
[ -s "$ROW" ] || fail ROW "no $ROW; hack/gate.sh writes it"
B="$REGISTRY/burn:3.12-slim"; BXS="$REGISTRY/burn-xs:3.12-slim"; BXXS="$REGISTRY/burn-xxs:3.12-slim"
cd "$GYM_DIR" || fail GYM_DIR "$GYM_DIR"
# shellcheck disable=SC1091
source .venv/bin/activate
snap() { echo "[$(date -u +%T)] $1: actors $(kubectl ate get actors -a "$ATESPACE" 2>/dev/null | awk 'NR>1{print $4}' | sed 's/ACTOR_STATE_//' | sort | uniq -c | tr -s ' \n' ' ') | workers active $(active_gym_workers) | restarts $(restarts) | $(tail -1 "$RUN_DIR/host-samples.txt" 2>/dev/null | cut -c21-130)"; }
promdump() { [ -n "$PROM_URL" ] || return 0
  if curl -sf -m 30 "$PROM_URL/api/v1/query?query=%7B__name__%3D~%22ate.%2A%22%7D" > "$OUT/prom-$1.json" 2>/dev/null; then
    echo "prom dump $1: $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["data"]["result"]))' "$OUT/prom-$1.json" 2>/dev/null) series"
  else rm -f "$OUT/prom-$1.json"; echo "prom dump $1: $PROM_URL did not answer"; fi; }
RESTARTS0=$(restarts)
STOP_MEM_USED_GIB="${STOP_MEM_USED_GIB:-$(( $(free -g | awk '/^Mem:/{print $2}') * 90 / 100 ))}"
STOP_NOTREADY_S="${STOP_NOTREADY_S:-60}"
DOCKER_ROOT=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
STOP_DISK_FREE_GB="${STOP_DISK_FREE_GB:-$(( $(df -BG --output=size "$DOCKER_ROOT" 2>/dev/null | tail -1 | tr -dc 0-9) / 10 ))}"
NOTREADY_SINCE=0; RULES=/dev/null
# rule_breach N: one sample line into RULES, then the broken rule on stdout, or nothing.
rule_breach() { local n=$1 crashed r m d nr now
  crashed=$(kubectl ate get actors -a "$ATESPACE" 2>/dev/null | grep -c CRASHED); r=$(restarts)
  m=$(free -g | awk '/^Mem:/{print $3}'); d=$(df -BG --output=avail "$DOCKER_ROOT" 2>/dev/null | tail -1 | tr -dc 0-9)
  nr=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}' | tr '\n' ' '); now=$(date +%s)
  echo "$(date -u +%T) crashed=$crashed restarts=$r mem_used=${m}G disk_free=${d}G notready=[${nr% }]" >> "$RULES"
  [ "$crashed" -gt $((n / 100)) ] && { echo "$crashed CRASHED actors (> 1 % of $n)"; return; }
  [ "$r" -gt "$RESTARTS0" ] && { echo "ate-system restarts $RESTARTS0 -> $r"; return; }
  [ "$m" -gt "$STOP_MEM_USED_GIB" ] && { echo "host memory used ${m}G > ${STOP_MEM_USED_GIB}G"; return; }
  [ -n "$d" ] && [ "$d" -lt "$STOP_DISK_FREE_GB" ] && { echo "disk free ${d}G < ${STOP_DISK_FREE_GB}G under $DOCKER_ROOT"; return; }
  if [ -n "$nr" ]; then
    [ "$NOTREADY_SINCE" -eq 0 ] && NOTREADY_SINCE=$now
    [ $((now - NOTREADY_SINCE)) -gt "$STOP_NOTREADY_S" ] && echo "nodes not Ready for over ${STOP_NOTREADY_S}s: ${nr% }"
  else NOTREADY_SINCE=0; fi; return 0; }
# watch_rules N NAME: every 15 s until killed; a breach ends the arm's processes and marks the arm.
watch_rules() { local msg; while sleep 15; do msg=$(rule_breach "$1"); [ -n "$msg" ] || continue
  ev "STOP RULE: $msg"; touch "$RUN_DIR/$2.stopped"; pkill -f '[g]ym eval run|[b]urn_driver.py|[r]un_arm.sh' 2>/dev/null; return; done; }
stop_rule() { local msg; [ -e "$RUN_DIR/$2.stopped" ] && return 1; msg=$(rule_breach "$1"); [ -n "$msg" ] || return 0; ev "STOP RULE: $msg"; return 1; }
# collect NAME SINCE_S: what the arm leaves in the cluster, before its cleanup.
collect() { local p
  kubectl ate get actors -a "$ATESPACE" > "$OUT/$1-actors.txt" 2>/dev/null
  kubectl -n ate-system logs -l app=ate-api-server --all-containers --prefix --max-log-requests=16 --since="$2s" > "$OUT/$1-apiserver.log" 2>/dev/null
  for p in $(kubectl -n ate-demo-sandbox get pods --no-headers 2>/dev/null | awk '$1 ~ /^gym-workerpool/ && $4 > 0 {print $1}'); do
    kubectl -n ate-demo-sandbox logs "$p" --previous --tail=3000 > "$OUT/$1-$p-previous.log" 2>/dev/null
  done
  [ "$RUNTIME" = microvm ] && bash "$LD/restore-phases.sh" "$2" "$OUT/$1-restore-phases.jsonl" | tee -a "$EV"; return 0; }
# At an arm boundary nothing else runs in the atespace, so the whole atespace is the arm's leftovers.
cleanup_actors() { python3 "$REPO/scripts/delete_actors.py" "$ATESPACE" --all 2>&1 | tail -1 | sed 's/^/cleanup: /'
  local i left=1; for i in $(seq 1 36); do left=$(actors_left); [ "$left" -eq 0 ] && break; sleep 5; done
  echo "cleanup: $left actors left after $((i * 5)) s" | tee -a "$EV"; }
pgrep -f "ladder/host-sampler.sh" >/dev/null || { setsid nohup bash "$LD/host-sampler.sh" "$RUN_DIR/host-samples.txt" 5 > "$LOG_DIR/host-sampler.log" 2>&1 < /dev/null & }
ev "start $MODE; slots $SLOTS; api $ATEAPI_ADDR; restarts baseline $RESTARTS0"

# run_burn NAME IMAGE SHARDS STAGGER N STEPS GAP POLICY BURN ALLOC: burn_driver.py over SHARDS
# processes of N/SHARDS sandboxes each (one gRPC channel per shard), one tsv per shard.
run_burn() { local name=$1 image=$2 shards=$3 stagger=$4 n=$5; shift 5
  [ $((n % shards)) -eq 0 ] || fail SHARDS "$name: $n sandboxes do not split into $shards shards"
  ev "start $name: image $image, $shards x $((n / shards)) sandboxes, stagger $stagger, steps/gap/policy/burn/alloc $*"; snap "before-$name"; cleanup_actors
  local T0=$SECONDS; rm -f "$RUN_DIR/$name.stopped"
  ( while true; do snap "during-$name" >> "$RUN_DIR/$name-snaps.txt"; sleep 30; done ) & local SN=$!
  RULES="$RUN_DIR/$name-rules.txt"; : > "$RULES"; watch_rules "$n" "$name" & local WR=$!
  local pids=() i; for i in $(seq 1 "$shards"); do IMAGE=$image OUT="$RUN_DIR/$name-$i.tsv" STAGGER_S=$stagger timeout 3600 python3 -u "$LD/burn_driver.py" $((n / shards)) "$@" > "$LOG_DIR/$name-$i.log" 2>&1 & pids+=($!); done
  local rc=0 pid; for pid in "${pids[@]}"; do wait "$pid" || rc=1; done; kill "$SN" "$WR" 2>/dev/null
  ev "end $name rc=$rc"; for i in $(seq 1 "$shards"); do grep -E "RESULT|policy=" "$LOG_DIR/$name-$i.log" | tail -2 | cut -c1-240 | sed "s/^/shard $i: /" | tee -a "$EV"; done; promdump "$name"; snap "after-$name" | tee -a "$EV"
  collect "$name" $((SECONDS - T0 + 30))
  stop_rule "$n" "$name"; local sr=$?; cleanup_actors; return $(( rc != 0 || sr != 0 )); }

# run_gym NAME CFG N THINK_S [TIMEBOX_S]: restart the replay policy with the think time, then one
# run_arm (a warm-up rollout, then N rollouts of the gate row at once).
run_gym() { local name=$1 cfg=$2 n=$3 think=$4 box=${5:-0} rc
  pkill -f "[r]eplay_policy.py" 2>/dev/null; sleep 2
  nohup python "$REPO/scripts/replay_policy.py" --rollouts responses_api_agents/mini_swe_agent_2/data/example_rollouts.jsonl --port 9797 --think-mean-s "$think" --seed 1 > "$LOG_DIR/replay-$name.log" 2>&1 < /dev/null & sleep 4
  curl -sf localhost:9797/healthz >/dev/null || { ev "replay policy failed to start for $name"; return 1; }
  ev "start $name (run_arm $cfg n=$n think=$think box=$box)"; snap "before-$name"; cleanup_actors
  local T0=$SECONDS; rm -f "$RUN_DIR/$name.stopped"
  ( while true; do snap "during-$name" >> "$RUN_DIR/$name-snaps.txt"; sleep 30; done ) & local SN=$!
  RULES="$RUN_DIR/$name-rules.txt"; : > "$RULES"; watch_rules "$n" "$name" & local WR=$!
  export GYM_DIR RUN_DIR LOG_DIR ATESPACE INPUT="$ROW" EXTRA_CONFIGS="$RUN_DIR/image-rewrites.yaml,$AGENT_CFG" REPLAY_URL=http://127.0.0.1:9797
  if [ "$box" -gt 0 ]; then timeout "$box" bash "$REPO/scripts/run_arm.sh" "$name" "$cfg" "$n" > "$LOG_DIR/$name.runner.log" 2>&1; rc=$?
  else bash "$REPO/scripts/run_arm.sh" "$name" "$cfg" "$n" > "$LOG_DIR/$name.runner.log" 2>&1; rc=$?; fi
  kill "$SN" "$WR" 2>/dev/null
  ev "end $name rc=$rc (124 = time box)"; grep -E "warmup|policy=|reward|Per-task|worker-seconds|eval_error|leaked" "$LOG_DIR/$name.runner.log" | cut -c1-220 | tee -a "$EV"; promdump "$name"; snap "after-$name" | tee -a "$EV"
  collect "$name" $((SECONDS - T0 + 30))
  stop_rule "$n" "$name"; local sr=$?; cleanup_actors; return $(( rc != 0 || sr != 0 )); }

N1=$SLOTS; N2=$((SLOTS * 2)); N4=$((SLOTS * 4)); N6=$((SLOTS * 6)); N8=$((SLOTS * 8))
FAILED=0; bad() { echo "$1 ended with a failure or a stop rule"; FAILED=1; }
case "$MODE" in
  s2a)     run_gym "s2-$N1-never" "$NEVER" "$N1" 2 || bad "s2-$N1-never"; run_gym "s2-$N1-pause" "$SAT" "$N1" 2 || bad "s2-$N1-pause" ;;
  s2never) run_gym "s2-$N1-never" "$NEVER" "$N1" 2 || bad "s2-$N1-never" ;;
  s2pause) run_gym "s2-$N1-pause" "$SAT" "$N1" 2 || bad "s2-$N1-pause" ;;
  s1b4x)   START_BARRIER=0 run_burn "s1b-$N4-never" "$BXS" 4 0.20 "$N4" 15 0 never 20 0.55 || bad "s1b-$N4-never" ;;
  light)   START_BARRIER=0 run_burn "s1b-$N8-light" "$BXXS" 8 2.7 "$N8" 40 30 never 3 0.25 || bad "s1b-$N8-light" ;;
  s2b)     run_gym "s2-$N2-pause" "$SAT" "$N2" 60 || bad "s2-$N2-pause" ;;
  paced)   START_BARRIER=1 run_burn "s1b-$N4-paced" "$BXS" 4 1.0 "$N4" 15 0 never 20 0.55 || bad "s1b-$N4-paced" ;;
  s4)      START_BARRIER=0 run_burn "s4-$N1-full" "$B" 8 0.1 "$N1" 30 0 never 20 "$HOLDER_GIB" || bad "s4-$N1-full" ;;
  s2c)     run_gym "s2-$N2-never" "$NEVER" "$N2" 2 || bad "s2-$N2-never" ;;
  s2d)     run_gym "s2-$N4-pause" "$SAT" "$N4" 60 5400 || bad "s2-$N4-pause" ;;
  s2e)     run_gym "s2-$N6-pause" "$SAT" "$N6" 60 7200 || bad "s2-$N6-pause" ;;
  s2f)     run_gym "s2-$N8-pause" "$SAT" "$N8" 60 7200 || bad "s2-$N8-pause" ;;
  s2g)     run_gym "s2-$N8-pause-t120" "$SAT" "$N8" 120 7200 || bad "s2-$N8-pause-t120" ;;
  s2h)     run_gym "s2-$N8-never" "$NEVER" "$N8" 60 7200 || bad "s2-$N8-never" ;;
  soak)    for i in 1 2 3; do run_gym "soak-$STAMP-$i-$N1-pause" "$SAT" "$N1" 2 || bad "soak-$STAMP-$i-$N1-pause"; run_gym "soak-$STAMP-$i-$N1-never" "$NEVER" "$N1" 2 || bad "soak-$STAMP-$i-$N1-never"; done ;;
  *) echo "unknown mode $MODE"; exit 2 ;;
esac
cp "$RUN_DIR"/*.tsv "$RUN_DIR"/*-snaps.txt "$RUN_DIR"/host-samples.txt "$RUN_DIR"/*_aggregate_metrics.json "$RUN_DIR"/*-samples.txt "$RUN_DIR"/*-rules.txt "$OUT"/ 2>/dev/null
ev "done ($MODE); outputs in $OUT; failed=$FAILED"
exit $FAILED
