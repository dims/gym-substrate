#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The hard stop of a run without touching the cluster: the ladder processes, the Gym eval and
# servers, Ray and the replay policy, then every actor of the atespace (up to six passes).
#   scripts/ladder/stop-gym.sh
# Environment: WORK (hack/_lib.sh), GYM_DIR (default WORK/gym).
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
GYM_DIR="${GYM_DIR:-$WORK/gym}"; EV="$RUN_DIR/events.log"; LD="$(cd "$(dirname "$0")" && pwd)"
echo "$(date -u +%FT%TZ) stop-gym: start" | tee -a "$EV"
bash "$LD/kill-runs.sh"
pkill -f "[g]ym eval run" 2>/dev/null; pkill -f "[g]ym env start" 2>/dev/null; pkill -f "[r]eplay_policy.py" 2>/dev/null
[ -x "$GYM_DIR/.venv/bin/ray" ] && "$GYM_DIR/.venv/bin/ray" stop --force >/dev/null 2>&1
sleep 5
echo "left: ladder=$(pgrep -fc '[l]adder|[r]un_arm|[b]urn_driver') gym=$(pgrep -fc '[g]ym (eval|env)|[r]ay::|[r]eplay_policy')"
NODE_IP=$(node_ip); n=-1
if [ -n "$NODE_IP" ] && [ -x "$GYM_DIR/.venv/bin/python" ]; then
  for _ in 1 2 3 4 5 6; do
    ATEAPI_ADDR="$NODE_IP:30443" "$GYM_DIR/.venv/bin/python" "$REPO/scripts/delete_actors.py" "$ATESPACE" --all >> "$EV" 2>&1; sleep 10
    n=$(actors_left); [ "$n" -eq 0 ] && break
  done
fi
echo "$(date -u +%FT%TZ) stop-gym: done; actors left $n; mem_used $(free -g | awk '/Mem:/{print $3}')G" | tee -a "$EV"
