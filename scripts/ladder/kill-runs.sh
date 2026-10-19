#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Kill every ladder process by PID (the patterns are bracketed so this script never matches
# itself): the chain, the ladder, run_arm, the burn drivers and their timeouts.
#   scripts/ladder/kill-runs.sh
# shellcheck disable=SC2009  # ps + a bracketed grep on purpose: pgrep -f would match this script's own command line
PAT='[l]adder-chain.sh|[l]adder.sh|[r]un_arm.sh|[b]urn_driver.py|[t]imeout 3600 python'
for pass in 1 2; do
  for p in $(ps -eo pid,args | grep -E "$PAT" | awk '{print $1}'); do
    if [ "$pass" = 1 ]; then kill "$p" 2>/dev/null; else kill -9 "$p" 2>/dev/null; fi
  done
  sleep 2
done
echo "left: $(ps -eo args | grep -c -E "$PAT")"
