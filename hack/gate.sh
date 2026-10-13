#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The acceptance for a cluster and a Gym checkout: the live smoke, then one mini_swe_agent_2
# rollout of GATE_INSTANCE through scripts/run_arm.sh with the replay policy as the model.
#   hack/gate.sh [NAME]
# Environment: WORK, GYM_DIR (default WORK/gym), GATE_INSTANCE (default
# scikit-learn__scikit-learn-14141), THINK_S (default 2), REPLAY_URL.
set -uo pipefail
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/_lib.sh"
NAME=${1:-gate-$(date -u +%H%M%S)}
GYM_DIR="${GYM_DIR:-$WORK/gym}"; GATE_INSTANCE="${GATE_INSTANCE:-scikit-learn__scikit-learn-14141}"; THINK_S="${THINK_S:-2}"
REPLAY_URL="${REPLAY_URL:-http://127.0.0.1:9797}"
NODE_IP=$(node_ip); [ -n "$NODE_IP" ] || fail NODE_IP "no $RUN_DIR/node-ip; run hack/kind-up.sh first"
cd "$GYM_DIR" || fail GYM_DIR "$GYM_DIR"
# shellcheck disable=SC1091
source .venv/bin/activate

step "replay policy"
if ! curl -sf "$REPLAY_URL/healthz" >/dev/null; then
  nohup python "$REPO/scripts/replay_policy.py" --rollouts responses_api_agents/mini_swe_agent_2/data/example_rollouts.jsonl --port "${REPLAY_URL##*:}" --think-s "$THINK_S" > "$LOG_DIR/replay.log" 2>&1 < /dev/null &
  sleep 4
  curl -sf "$REPLAY_URL/healthz" >/dev/null || { tail -5 "$LOG_DIR/replay.log"; fail REPLAY; }
fi
echo "replay ok at $REPLAY_URL"

step "smoke"
ATEAPI_ADDR="$NODE_IP:30443" ATENET_ADDR="$NODE_IP:30080" ATESPACE="$ATESPACE" python "$REPO/scripts/smoke_provider.py" "$REGISTRY/python:3.12-slim" pause_after_exec > "$LOG_DIR/smoke-$NAME.log" 2>&1; rc=$?
grep -E "^(create|parked|exec|timeout|status|download|close|RESULT)" "$LOG_DIR/smoke-$NAME.log"
[ $rc -eq 0 ] || { grep -v -E "^(INFO|DEBUG)" "$LOG_DIR/smoke-$NAME.log" | tail -20; fail SMOKE; }
LEFT=$(actors_left); echo "actors left: $LEFT"; [ "$LEFT" -eq 0 ] || fail SMOKE "$LEFT actors left"

step "gate row $GATE_INSTANCE"
python3 - "$GATE_INSTANCE" responses_api_agents/mini_swe_agent_2/data/example.jsonl "$RUN_DIR/$GATE_INSTANCE.jsonl" <<'PY' || fail GATE_ROW
import json, sys
inst, src, dst = sys.argv[1:4]
rows = [line for line in open(src) if line.strip() and json.loads(line).get("instance_id") == inst]
if not rows:
    sys.exit(f"no row for {inst} in {src}")
open(dst, "w").write(rows[0])
PY
echo "gate row: $RUN_DIR/$GATE_INSTANCE.jsonl"

step "rollout $NAME"
export GYM_DIR RUN_DIR LOG_DIR REPLAY_URL ATESPACE
INPUT="$RUN_DIR/$GATE_INSTANCE.jsonl" EXTRA_CONFIGS="$RUN_DIR/image-rewrites.yaml" \
  bash "$REPO/scripts/run_arm.sh" "$NAME" "$RUN_DIR/substrate.yaml" 1 2>&1 | tee "$LOG_DIR/arm-$NAME.out"
AV="$GYM_DIR/responses_api_agents/mini_swe_agent_2/.venv/bin/python"
if [ -x "$AV" ] && "$AV" -c "import gym_substrate" 2>/dev/null; then echo "agent venv has the plugin"; else echo "agent venv: plugin not found"; fi
grep -q "eval_exit=0 leaked_actors=0" "$LOG_DIR/arm-$NAME.out" || fail GATE "eval exit or leaked actors"
grep -q "errored=0" "$LOG_DIR/arm-$NAME.out" || fail GATE "errored rollouts"
grep -q "reward_mean=1.00" "$LOG_DIR/arm-$NAME.out" || fail GATE "reward below 1.0"
echo "GATE PASS $NAME"
