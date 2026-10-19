#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# A burst on one cluster: N small sandboxes created together, STEPS short burns with a pause and a
# resume between them (pause_after_exec), then all deleted, while scripts/probes/host-counts.sh
# samples the host. The burn driver's own table gives create, exec (resume included) and close
# latencies; the counts file gives the peak processes, threads, file descriptors and taps.
#   scripts/probes/burst.sh [N] [STEPS] [GAP_S]        (defaults 64, 3, 30)
# Environment: WORK (hack/_lib.sh), GYM_DIR (default WORK/gym), IMAGE (default the burn-xs tag).
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
N=${1:-64}; STEPS=${2:-3}; GAP=${3:-30}
GYM_DIR="${GYM_DIR:-$WORK/gym}"; IMAGE="${IMAGE:-$REGISTRY/burn-xs:3.12-slim}"; LD="$(cd "$(dirname "$0")/../ladder" && pwd)"
NODE_IP=$(node_ip); [ -n "$NODE_IP" ] || fail NODE_IP "no $RUN_DIR/node-ip"
export ATEAPI_ADDR="$NODE_IP:30443" ATENET_ADDR="$NODE_IP:30080" ATESPACE RUN_DIR
cd "$GYM_DIR" || fail GYM_DIR "$GYM_DIR"
# shellcheck disable=SC1091
source .venv/bin/activate
[ "$(actors_left)" -eq 0 ] || fail ACTORS_LEFT "$(actors_left) actors in $ATESPACE"
STAMP=$(date -u +%H%M%S); COUNTS="$RUN_DIR/host-counts-burst-$STAMP.txt"
bash "$(dirname "$0")/host-counts.sh" "$COUNTS" 5 & SAMPLER=$!
step "burst: $N x $IMAGE, $STEPS x 3 s burns, gap $GAP s, pause_after_exec"
IMAGE=$IMAGE OUT="$RUN_DIR/burst-$STAMP.tsv" STAGGER_S=0.1 EXEC_CONCURRENCY=8192 PROBE_TIMEOUT_S=660 \
  timeout 3600 python3 -u "$LD/burn_driver.py" "$N" "$STEPS" "$GAP" pause_after_exec 3 0.1 2>&1 | tee "$LOG_DIR/burst-$STAMP.log" | grep -E '^(phase|create|exec|close|policy=|RESULT|STEP-FAILED|ERROR)' | cut -c1-220
kill "$SAMPLER" 2>/dev/null
step "peak host counts"
for f in procs threads fds inotify taps; do printf '%s peak %s\n' "$f" "$(grep -o "$f=[0-9]*" "$COUNTS" | cut -d= -f2 | sort -n | tail -1)"; done
echo "actors left: $(actors_left)"; grep -q '^RESULT PASS' "$LOG_DIR/burst-$STAMP.log" && echo "BURST PASS" || echo "BURST FAIL"
