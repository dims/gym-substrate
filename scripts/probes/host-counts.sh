#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Host-wide counts that a dense sandbox fleet pushes against, one line per sample: processes,
# threads, open files, inotify instances, tap devices, memory used, load. Append-only; stop with
# kill. Read the peak with `sort -t= -k3 -n` on the field you care about.
#   scripts/probes/host-counts.sh [OUT] [INTERVAL_S]
set -u
OUT=${1:-${RUN_DIR:-$HOME/gym-substrate-run/run}/host-counts.txt}; IV=${2:-10}
mkdir -p "$(dirname "$OUT")"
echo "# $(date -u +%FT%TZ) host-counts start interval=${IV}s pid_max=$(sysctl -n kernel.pid_max) threads-max=$(sysctl -n kernel.threads-max) file-max=$(sysctl -n fs.file-max) inotify-instances-max=$(sysctl -n fs.inotify.max_user_instances)" >> "$OUT"
while :; do
  procs=$(find /proc -maxdepth 1 -regex '/proc/[0-9]+' 2>/dev/null | wc -l)
  threads=$(awk '{print $2}' /proc/loadavg | cut -d/ -f2)
  fds=$(awk '{print $1}' /proc/sys/fs/file-nr)
  inotify=$(find /proc/[0-9]*/fd -lname 'anon_inode:inotify' 2>/dev/null | wc -l)
  taps=$(ip -o link 2>/dev/null | grep -c -E ': tap|: vmtap' || true)
  echo "$(date -u +%FT%TZ) procs=$procs threads=$threads fds=$fds inotify=$inotify taps=$taps mem_used=$(free -g | awk '/^Mem:/{print $3}')G load=$(cut -d' ' -f1-3 /proc/loadavg | tr ' ' ,)" >> "$OUT"
  sleep "$IV"
done
