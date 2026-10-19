#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The state of a borrowed host before anything is changed on it, as the OS user. Prints it, and
# with --save keeps the parts the revert and the wipe compare against under
# ~/.gym-substrate-host/baseline (home listing, packages, sysctls, groups, a timestamp).
#   hack/host/baseline.sh [--save]
set -u
B="$HOME/.gym-substrate-host/baseline"
echo "== whoami: $(id) HOME=$HOME host=$(hostname) $(date -u +%FT%TZ)"
echo "== uptime: $(uptime)"; echo "== who:"; who
echo "== user processes (non-system):"; ps -eo user=,etimes=,args= --sort=-etimes | awk '$1 != "root" && $1 !~ /^(_|systemd|messagebus|syslog|daemon|nobody|polkitd|chrony|cmd|cm)/' | cut -c1-200
KEYS="fs.inotify.max_user_instances fs.inotify.max_user_watches net.ipv4.neigh.default.gc_thresh1 net.ipv4.neigh.default.gc_thresh2 net.ipv4.neigh.default.gc_thresh3 net.netfilter.nf_conntrack_max fs.aio-max-nr net.core.somaxconn net.ipv4.ip_local_port_range kernel.pid_max kernel.threads-max vm.max_map_count fs.file-max"
echo "== sysctls:"; for k in $KEYS; do printf '%s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null | tr '\t' ' ')"; done
echo "== thp: enabled $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null) shmem $(cat /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null); $(grep Hugepagesize /proc/meminfo)"
echo "== kvm: $(ls -l /dev/kvm 2>&1) | groups $(id -Gn)"
echo "== dpkg ii: $(dpkg -l 2>/dev/null | grep -c '^ii')"; echo "== docker group: $(getent group docker || echo none)"; echo "== docker/kind/go/uv: $(command -v docker kind go uv 2>/dev/null | tr '\n' ' ')"
echo "== kernel: $(uname -r) pagesize $(getconf PAGESIZE) threads $(nproc) mem $(free -g | awk '/Mem:/ {print $2}')G disk $(df -h / | awk 'NR==2 {print $4" free on "$1}')"
echo "== disks: $(lsblk -dno NAME,SIZE,MOUNTPOINTS 2>/dev/null | tr -s ' ' | tr '\n' ';')"
echo "== egress: github $(curl -s -m 8 -o /dev/null -w '%{http_code}' https://github.com) dockerhub $(curl -s -m 8 -o /dev/null -w '%{http_code}' https://registry-1.docker.io/v2/) ghcr $(curl -s -m 8 -o /dev/null -w '%{http_code}' https://ghcr.io/v2/) k8s $(curl -s -m 8 -o /dev/null -w '%{http_code}' https://registry.k8s.io/v2/)"
home_entries() { find "$HOME" -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -v -x '.gym-substrate-host' | sort; }
echo "== sudo: $(sudo -n true 2>&1 | head -1)"; echo "== tmp: $(find /tmp -mindepth 1 -maxdepth 1 2>/dev/null | wc -l) entries, $(find /tmp -maxdepth 1 -user "$(id -un)" 2>/dev/null | wc -l) mine"
echo "== home: $(home_entries | tr '\n' ' ')"
if [ "${1:-}" = --save ]; then
  if [ -e "$B/home.txt" ]; then echo "baseline already saved at $(cat "$B/when.txt"); not overwritten"; exit 0; fi
  mkdir -p "$B"; chmod 700 "$HOME/.gym-substrate-host"
  date -u +%FT%TZ > "$B/when.txt"
  home_entries > "$B/home.txt"
  dpkg-query -W -f '${Package}\n' 2>/dev/null | sort > "$B/pkgs.txt"
  for k in $KEYS; do printf '%s=%s\n' "$k" "$(sysctl -n "$k" 2>/dev/null | tr '\t' ' ')"; done > "$B/sysctl.txt"
  id -Gn > "$B/groups.txt"
  echo "baseline saved under $B ($(wc -l < "$B/home.txt") home entries, $(wc -l < "$B/pkgs.txt") packages)"
fi
