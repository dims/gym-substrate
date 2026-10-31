#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The "Actor restore phases" lines the gym workers logged in the last SINCE_S seconds, into OUT,
# then their summary (restore_phases.py): per phase n, min, median, p90, max, and the slow reseeds.
#   scripts/ladder/restore-phases.sh SINCE_S OUT
# Environment: WORK (hack/_lib.sh).
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
SINCE=${1:?seconds}; OUT=${2:?output file}; : > "$OUT"
for p in $(kubectl -n ate-demo-sandbox get pods --no-headers 2>/dev/null | awk '$1 ~ /^gym-workerpool/ {print $1}'); do
  kubectl -n ate-demo-sandbox logs "$p" --since="${SINCE}s" 2>/dev/null | grep -F 'Actor restore phases' >> "$OUT"
done
python3 "$(dirname "$0")/restore_phases.py" "$OUT"
