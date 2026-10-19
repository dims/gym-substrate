#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# One arm of a pause-against-never comparison: restart the Gym servers with a
# provider config, run N rollouts of one input row at once, print a summary.
#
#   run_arm.sh NAME PROVIDER_CONFIG N
#
# Environment: GYM_DIR (the Gym checkout with its .venv; default: the current
# directory), INPUT (the jsonl row to repeat; default: mini_swe_agent_2's
# example.jsonl, first row), RUN_DIR and LOG_DIR (default ~/gym-run and ~/logs),
# REPLAY_URL (default http://127.0.0.1:9797), EXTRA_CONFIGS (comma-separated
# config paths appended to the servers' config, such as an image-rewrites
# file), ATESPACE (default nemo-gym), SERVER_WAIT_S (default 600: the first start builds
# the agent server's venv).
set -uo pipefail
NAME="$1"; CFG="$2"; N="$3"
GYM_DIR="${GYM_DIR:-$PWD}"; RUN_DIR="${RUN_DIR:-$HOME/gym-run}"; LOG_DIR="${LOG_DIR:-$HOME/logs}"
REPLAY_URL="${REPLAY_URL:-http://127.0.0.1:9797}"; ATESPACE="${ATESPACE:-nemo-gym}"
INPUT="${INPUT:-$GYM_DIR/responses_api_agents/mini_swe_agent_2/data/example.jsonl}"
AGENT_CFG=responses_api_agents/mini_swe_agent_2/configs/mini_swe_agent_2.yaml
MODEL_CFG=responses_api_models/openai_model/configs/openai_model.yaml
mkdir -p "$RUN_DIR" "$LOG_DIR"
cd "$GYM_DIR" || exit 1
# shellcheck disable=SC1091
source .venv/bin/activate

# Preflight: the replay policy answers, and no actor is left from an earlier
# run. Leftovers are not deleted here; see scripts/delete_actors.py.
curl -sf "$REPLAY_URL/healthz" >/dev/null || { echo "replay policy is not answering at $REPLAY_URL"; exit 1; }
LEFT=$(kubectl ate get actors -a "$ATESPACE" | awk 'NR>1' | wc -l) || { echo "cannot list actors in $ATESPACE"; exit 1; }
[ "$LEFT" -eq 0 ] || { echo "preflight: $LEFT actors left in $ATESPACE; delete them first"; exit 1; }

# Stop the earlier Gym servers by their own listen ports (the log also names
# the replay policy's URL, so match the Uvicorn lines only), then Ray. Then wait
# until those ports are free: a server still shutting down makes the next
# `gym env start` die with EADDRINUSE on its own port.
PORTS=$(grep -o "Uvicorn running on http://127.0.0.1:[0-9]*" "$LOG_DIR/gym-env.log" 2>/dev/null | grep -o "[0-9]*$" | sort -u)
for p in $PORTS; do fuser -k -n tcp "$p" >/dev/null 2>&1; done
ray stop --force >/dev/null 2>&1
for _ in $(seq 1 30); do
  busy=0; for p in $PORTS; do ss -ltnH "sport = :$p" 2>/dev/null | grep -q . && busy=1; done
  [ "$busy" -eq 0 ] && break; sleep 1
done
[ "$busy" -eq 0 ] || { echo "earlier Gym servers still hold their ports after 30 s: $(for p in $PORTS; do ss -ltnH "sport = :$p" 2>/dev/null | grep -q . && printf '%s ' "$p"; done)"; exit 1; }
sleep 2
SERVER_LOG="$LOG_DIR/gym-env-$NAME.log"
: > "$SERVER_LOG"; ln -sf "$SERVER_LOG" "$LOG_DIR/gym-env.log"
CONFIGS="$AGENT_CFG,$CFG,$MODEL_CFG${EXTRA_CONFIGS:+,$EXTRA_CONFIGS}"
nohup gym env start "+config_paths=[$CONFIGS]" > "$SERVER_LOG" 2>&1 < /dev/null &
n=0
for _ in $(seq 1 $(( ${SERVER_WAIT_S:-600} / 5 ))); do
  sleep 5; n=$(grep -c "startup complete" "$SERVER_LOG"); [ "$n" -ge 4 ] && break
done
[ "$n" -ge 4 ] || { echo "servers failed to start within ${SERVER_WAIT_S:-600}s; see $SERVER_LOG"; exit 1; }

# Warm-up: one rollout so the agent server's Ray runtime and venv are up before
# N requests arrive at once. Not part of the measurement.
gym eval run --no-serve --agent mini_swe_agent_2 --input "$INPUT" --output "$RUN_DIR/$NAME-warmup.jsonl" \
  --limit 1 --num-repeats 1 > "$LOG_DIR/$NAME-warmup.log" 2>&1 \
  || { echo "warm-up failed; see $LOG_DIR/$NAME-warmup.log"; exit 1; }

# Pair the think times with the other arm: the replay hands out seeded draws in
# request order and restarts its counters on /reset.
curl -sf -X POST "$REPLAY_URL/reset" >/dev/null || { echo "replay /reset failed"; exit 1; }

START=$(date -u +%Y-%m-%dT%H:%M:%SZ); T0=$(date +%s)
# Actor states from the API every 5 s: the occupancy source, since container
# logs rotate away.
SAMPLES="$RUN_DIR/$NAME-samples.txt"; : > "$SAMPLES"
( while true; do
    echo "$(date -u +%H:%M:%S) $(kubectl ate get actors -a "$ATESPACE" 2>/dev/null | grep -o 'ACTOR_STATE_[A-Z]*' | sort | uniq -c | tr -s ' \n' ' ')" >> "$SAMPLES"
    sleep 5
  done ) &
SAMPLER=$!
gym eval run --no-serve --agent mini_swe_agent_2 --input "$INPUT" --output "$RUN_DIR/$NAME.jsonl" \
  --limit 1 --num-repeats "$N" > "$LOG_DIR/$NAME.log" 2>&1
EVAL_EXIT=$?
END=$(date -u +%Y-%m-%dT%H:%M:%SZ); WALL=$(( $(date +%s) - T0 ))
kill "$SAMPLER" 2>/dev/null
sleep 5
LEAKED=$(kubectl ate get actors -a "$ATESPACE" 2>/dev/null | awk 'NR>1' | wc -l)
echo "$NAME policy=$(grep -o 'suspend_policy: [a-z_]*' "$CFG") n=$N wall=${WALL}s eval_exit=$EVAL_EXIT leaked_actors=$LEAKED start=$START end=$END"
grep -E "\"mean/reward\"|eval_error_rate|Per-task latency|resolved_task_count" "$LOG_DIR/$NAME.log"
python3 - "$RUN_DIR/$NAME.jsonl" "$SAMPLES" <<'PY'
import json, re, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
errored = sum(1 for r in rows if (r.get("metadata") or {}).get("error"))
reward = sum(r.get("reward") or 0 for r in rows) / max(len(rows), 1)
print(f"rollouts={len(rows)} reward_mean={reward:.2f} errored={errored}")
held = []
for line in open(sys.argv[2]):
    counts = {s: int(n) for n, s in re.findall(r"(\d+) ACTOR_STATE_([A-Z]+)", line)}
    held.append(sum(counts.get(s, 0) for s in ("RESUMING", "RUNNING", "SUSPENDING")))
if held:
    print(f"samples={len(held)} mean_held={sum(held) / len(held):.1f} max_held={max(held)} worker_seconds~{sum(held) * 5}")
PY
