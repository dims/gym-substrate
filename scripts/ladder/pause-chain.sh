#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Stop the ladder chain, its ladder, run_arm, the burn drivers and the Gym eval by PID, then
# delete the actors of the named template. One process snapshot, one kill: parents and children
# together, so no parent starts a new stage after its child dies. Use it at a stage boundary.
#   scripts/ladder/pause-chain.sh [TEMPLATE_NAME_TO_DELETE]
# Environment: WORK (hack/_lib.sh), GYM_DIR (default WORK/gym, for its venv).
# shellcheck disable=SC2009  # ps + a bracketed grep on purpose: pgrep -f would match this script's own command line
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
TPL=${1:-}; EV="$RUN_DIR/events.log"; GYM_DIR="${GYM_DIR:-$WORK/gym}"
echo "$(date -u +%FT%TZ) pause-chain: start" | tee -a "$EV"
PAT='[g]ym eval run|[b]urn_driver.py|[r]un_arm.sh|[l]adder.sh|[l]adder-chain.sh'
pids=$(ps -eo pid,args | grep -E "$PAT" | awk '{print $1}'); echo "killing: $(echo "$pids" | tr '\n' ' ')"
# shellcheck disable=SC2086
[ -n "$pids" ] && kill $pids 2>/dev/null; sleep 3
pids=$(ps -eo pid,args | grep -E "$PAT" | awk '{print $1}')
# shellcheck disable=SC2086
[ -n "$pids" ] && kill -9 $pids 2>/dev/null; sleep 1
echo "left: $(ps -eo args | grep -c -E "$PAT")"
if [ -n "$TPL" ]; then
  names=$(kubectl ate get actors -a "$ATESPACE" 2>/dev/null | awk -v t="$TPL" 'NR>1 && $3 ~ t {print $2}'); n=$(echo "$names" | grep -c .)
  echo "actors of $TPL: $n"
  # shellcheck disable=SC2086  # the names are meant to split
  [ "$n" -eq 0 ] || ATEAPI_ADDR="$(node_ip):30443" "$GYM_DIR/.venv/bin/python" "$REPO/scripts/delete_actors.py" "$ATESPACE" $names 2>&1 | tail -1
fi
echo "actors left in $ATESPACE: $(actors_left)" | tee -a "$EV"
echo "$(date -u +%FT%TZ) pause-chain: done" | tee -a "$EV"
