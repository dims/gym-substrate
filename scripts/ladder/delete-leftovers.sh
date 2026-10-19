#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# At an arm boundary: re-issue DeleteActor by name for actors still DELETING. A terminate that
# lost to its cleanup deadline leaves the actor DELETING with its slot held until a later delete
# finds the sandbox gone. Prints the names and the before and after counts.
#   scripts/ladder/delete-leftovers.sh
set -u
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/../../hack/_lib.sh"
EV="$RUN_DIR/events.log"
names=$(kubectl ate get actors -a "$ATESPACE" 2>/dev/null | awk 'NR>1 && $4 ~ /DELETING/ {print $2}'); n=$(echo "$names" | grep -c .)
echo "$(date -u +%FT%TZ) delete-leftovers: $n DELETING: $(echo "$names" | tr '\n' ' ' | cut -c1-200)" | tee -a "$EV"
for a in $names; do kubectl ate delete actor "$a" -a "$ATESPACE" --any-state >/dev/null 2>&1 & done; wait; sleep 5
echo "$(date -u +%FT%TZ) delete-leftovers: after: $(kubectl ate get actors -a "$ATESPACE" 2>/dev/null | awk 'NR>1 {print $4}' | sed 's/ACTOR_STATE_//' | sort | uniq -c | tr -s ' \n' ' ')" | tee -a "$EV"
