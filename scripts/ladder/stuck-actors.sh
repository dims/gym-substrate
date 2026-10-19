#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Read-only evidence on actors stuck in a transition (not RUNNING or PAUSED) at the end of a Gym
# arm: the eval's progress, two actors' status, and the ateapi, atelet and worker log lines about
# them from the last 15 minutes.
#   scripts/ladder/stuck-actors.sh [ARM_NAME]
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
ARM=${1:-}
[ -n "$ARM" ] && { echo "eval process: $(pgrep -f -c 'gym eval run') running; rows: $(grep -c . "$RUN_DIR/$ARM.jsonl" 2>/dev/null) in $RUN_DIR/$ARM.jsonl"; tail -2 "$LOG_DIR/$ARM.log" 2>/dev/null | cut -c1-200; }
stuck=$(kubectl ate get actors -a "$ATESPACE" 2>/dev/null | awk 'NR>1 && $4 !~ /RUNNING|PAUSED$/ {print $2}')
echo "stuck: $(echo "$stuck" | grep -c .) -> $(echo "$stuck" | tr '\n' ' ' | cut -c1-300)"
[ -n "$stuck" ] || exit 0
for a in $(echo "$stuck" | head -2); do echo "--- $a"; kubectl ate get actor "$a" -a "$ATESPACE" -o yaml 2>/dev/null | grep -E "state|message|reason|worker|lease|transition|Time|condition" | head -14 | sed 's/^/  /' | cut -c1-200; done
pat=$(echo "$stuck" | tr '\n' '|' | sed 's/|$//')
echo "--- ateapi logs (15 m) about them:"; kubectl -n ate-system logs -l app=ate-api-server --all-containers --prefix --since=15m --tail=4000 2>/dev/null | grep -E "$pat" | cut -c1-260 | tail -8
echo "--- atelet logs (15 m) about them:"; for p in $(kubectl -n ate-system get pods --no-headers | awk '/atelet/ {print $1}'); do kubectl -n ate-system logs "$p" -c atelet --since=15m --tail=3000 2>/dev/null | grep -E "$pat" | cut -c1-240 | tail -3 | sed "s/^/$p: /"; done
echo "--- worker logs on the transitioning actors' pods:"; for w in $(kubectl ate get actors -a "$ATESPACE" 2>/dev/null | awk 'NR>1 && $4 !~ /RUNNING|PAUSED$/ {print $5}' | sed 's#.*/##' | sort -u | head -2); do kubectl -n ate-demo-sandbox logs "$w" --since=20m --tail=2000 2>/dev/null | grep -i -E "checkpoint|pause|restore|terminate|error|fail" | cut -c1-240 | tail -4 | sed "s/^/$w: /"; done
