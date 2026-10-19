# shellcheck shell=bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Shared by the hack/ scripts: the work area, PATH, step and failure lines.
# Everything the scripts create lives under WORK; nothing outside it is removed.
WORK="${WORK:-$HOME/gym-substrate-run}"
# shellcheck disable=SC2034  # used by the scripts that source this file
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$WORK/run"; LOG_DIR="$WORK/logs"; BIN_DIR="$WORK/bin"
ATESPACE="${ATESPACE:-nemo-gym}"
REGISTRY="${REGISTRY:-localhost:5001}"
# The Substrate sandbox class the pools run: gvisor (default) or microvm (needs /dev/kvm).
RUNTIME="${RUNTIME:-gvisor}"
case "$RUNTIME" in gvisor|microvm) ;; *) echo "RUNTIME_FAILED: $RUNTIME is not gvisor or microvm"; exit 1 ;; esac
export PATH="$BIN_DIR:$HOME/.local/bin:/usr/local/go/bin:$HOME/go/bin:$PATH"
mkdir -p "$RUN_DIR" "$LOG_DIR" "$BIN_DIR"
step() { echo "== $(date -u +%FT%TZ) $*"; }
fail() { echo "${1}_FAILED${2:+: $2}"; exit 1; }
arch() { case "$(uname -m)" in x86_64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) uname -m ;; esac; }
swebench_arch() { case "$(arch)" in amd64) echo x86_64 ;; *) arch ;; esac; }
node_ip() { cat "$RUN_DIR/node-ip" 2>/dev/null; }
actors_left() { kubectl ate get actors -a "$ATESPACE" 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' '; }
# wait_for SECONDS WHAT COMMAND...: run COMMAND every 5 s until it succeeds or SECONDS pass.
wait_for() {
  local t=$1 what=$2 i; shift 2
  for ((i = 0; i < t; i += 5)); do "$@" && return 0; sleep 5; done
  echo "timed out after ${t}s waiting for $what"; return 1
}
