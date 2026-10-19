#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Run ladder modes one after another. A mode that fails does not stop the chain (its stop rule
# already ended its arm and its leftovers are deleted); `touch WORK/run/PAUSE` holds the chain
# before the next mode, `touch WORK/run/STOP` ends it there.
#   scripts/ladder/ladder-chain.sh MODE...
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
LD="$(cd "$(dirname "$0")" && pwd)"
for m in "$@"; do
  while [ -e "$RUN_DIR/PAUSE" ]; do sleep 10; done
  [ -e "$RUN_DIR/STOP" ] && { echo "$(date -u +%FT%TZ) chain: STOP before $m"; break; }
  bash "$LD/ladder.sh" "$m" || echo "$(date -u +%FT%TZ) chain: $m ended with a failure or a stop rule"
done
echo "$(date -u +%FT%TZ) chain: done"
