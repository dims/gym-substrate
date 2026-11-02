#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# host-sampler.sh [OUT] [INTERVAL_S]
# One line per sample: UTC time, CPU busy percent (/proc/stat), memory used (free -g),
# root NVMe write MB/s (/proc/diskstats), load; every 30 s also docker stats of the
# kind node containers (name=cpu%,mem). Each sample also writes the D-state processes by wait
# channel to <OUT minus .txt>-dstate.txt, to name the kernel wait behind a stall. Stop with kill;
# the files are append-only.
set -u
OUT=${1:-${RUN_DIR:-$HOME/gym-substrate-run/run}/host-samples.txt}; IV=${2:-5}
mkdir -p "$(dirname "$OUT")"
SRC=$(findmnt -no SOURCE /); DEV=$(lsblk -no PKNAME "$SRC" 2>/dev/null | head -1)
DEV=${DEV:-$(basename "$SRC" | sed 's/p[0-9]*$//')}
cpu() { awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5+$6}' /proc/stat; }   # total, idle+iowait
dsk() { awk -v d="$DEV" '$3==d {print $10; f=1} END{if(!f) print 0}' /proc/diskstats; }  # sectors written (512 B)
# shellcheck disable=SC2046  # the container ids are meant to split
nodes() { docker stats --no-stream --format '{{.Name}}={{.CPUPerc}},{{.MemUsage}}' $(docker ps -q -f 'name=^kind-') 2>/dev/null | sed 's# / [0-9.]*[KMGT]*i*B##' | tr '\n' ' '; }
read -r T0 I0 < <(cpu); W0=$(dsk); n=0
echo "# $(date -u +%FT%TZ) host-sampler start dev=$DEV interval=${IV}s" >> "$OUT"
while sleep "$IV"; do
  read -r T1 I1 < <(cpu); W1=$(dsk); dt=$((T1-T0)); [ "$dt" -gt 0 ] || dt=1
  busy=$(( 100*(dt-(I1-I0))/dt ))
  mbs=$(awk -v a="$W0" -v b="$W1" -v s="$IV" 'BEGIN{printf "%.1f", (b-a)*512/1048576/s}')
  line="$(date -u +%FT%TZ) busy=${busy}% mem_used=$(free -g | awk '/^Mem:/{print $3}')G disk_w=${mbs}MB/s load=$(cut -d' ' -f1-3 /proc/loadavg | tr ' ' ,)"
  n=$((n+1)); [ $(( (n*IV) % 30 )) -eq 0 ] && line="$line nodes: $(nodes)"
  echo "$line" >> "$OUT"; T0=$T1; I0=$I1; W0=$W1
  ds=$(ps -eo stat,wchan:40,comm --no-headers 2>/dev/null | awk '$1 ~ /^D/ {print $2"/"$3}' | sort | uniq -c | sort -rn)
  echo "$(date -u +%FT%TZ) D=$(echo "$ds" | awk '{s+=$1} END{print s+0}') $(echo "$ds" | head -8 | awk '{printf "%s:%s ", $1, $2}')" >> "${OUT%.txt}-dstate.txt"
done
