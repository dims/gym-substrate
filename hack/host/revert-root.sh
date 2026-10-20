#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Undo hack/host/prep-root.sh on a borrowed host, after hack/host/wipe.sh wipe: the files it wrote,
# the running sysctl values (back to what prep-root recorded), the packages it added (by name from
# its before/after lists, never autoremove), docker's state and group, the sshd priority, the mode of
# /dev/kvm (back to the baseline's).
#   sudo hack/host/revert-root.sh [USER] [keep-docker]
set -u
export DEBIAN_FRONTEND=noninteractive
U="${1:-${SUDO_USER:-}}"; [ -n "$U" ] || { echo "usage: revert-root.sh USER [keep-docker]"; exit 2; }
H=$(getent passwd "$U" | cut -d: -f6); P="$H/.gym-substrate-host/prep"
echo "== $(date -u +%FT%TZ) revert-root start for $U"
rm -f /etc/sysctl.d/91-gym-substrate.conf /etc/security/limits.d/91-gym-substrate.conf
if [ -s "$P/sysctl-before.txt" ]; then
  while IFS='=' read -r k v; do [ -n "$k" ] && sysctl -q -w "$k=$v"; done < "$P/sysctl-before.txt"
  echo "sysctls back to the recorded values: $(tr '\n' ' ' < "$P/sysctl-before.txt" | cut -c1-200)"
else echo "no sysctl-before.txt; running values left as they are (the files are gone, a reboot resets them)"; fi
gpasswd -d "$U" docker 2>/dev/null && echo "$U out of the docker group"
if [ "${2:-}" != keep-docker ]; then
  systemctl stop docker docker.socket containerd 2>/dev/null
  if apt-get purge -y -qq docker.io docker-buildx > "$P/apt-purge.log" 2>&1; then echo "docker packages purged"; else echo "apt purge FAILED"; tail -3 "$P/apt-purge.log"; fi
  rm -rf /var/lib/docker /etc/docker /var/lib/containerd /etc/containerd; groupdel docker 2>/dev/null; echo "docker state and group removed"
  echo "docker iptables chains still loaded until a reboot: $(iptables -S 2>/dev/null | grep -c DOCKER)"
fi
# Every other package prep-root added, by name from its before/after lists, including the
# dependencies apt pulled in for docker: a purge of docker.io leaves them installed. No autoremove:
# it took packages the lab had marked automatic on an earlier host. With keep-docker the docker
# packages and their dependencies stay.
if [ -s "$P/pkgs-before.txt" ] && [ -s "$P/pkgs-after.txt" ]; then
  added=$(comm -13 "$P/pkgs-before.txt" "$P/pkgs-after.txt" | grep -v -E '^(docker\.io|docker-buildx)$')
  [ "${2:-}" = keep-docker ] && added=$(echo "$added" | grep -v -E '^(containerd|runc|bridge-utils|pigz|ubuntu-fan)$')
  added=$(echo "$added" | tr '\n' ' ')
  if [ -n "$added" ]; then
    # shellcheck disable=SC2086
    if apt-get purge -y -qq $added >> "$P/apt-purge.log" 2>&1; then echo "purged: $added"; else echo "purge of added packages FAILED"; tail -3 "$P/apt-purge.log"; fi
  else echo "no other packages to purge"; fi
fi
# Substrate's hack/create-kind-cluster.sh bind-mounts the host's /dev/kvm into every kind node and
# runs chmod 666 on it there; a bind mount shares the inode, so the host's device stays world
# writable after the cluster is gone. Back to what baseline.sh --save recorded.
B="$H/.gym-substrate-host/baseline"
if [ -e /dev/kvm ] && [ -s "$B/kvm.txt" ]; then
  read -r mode user group < "$B/kvm.txt"
  if [ "$(stat -c '%a %U %G' /dev/kvm)" = "$mode $user $group" ]; then echo "/dev/kvm still $mode $user:$group"
  elif chmod "$mode" /dev/kvm && chown "$user:$group" /dev/kvm; then echo "/dev/kvm back to $mode $user:$group"
  else echo "/dev/kvm restore FAILED: $(stat -c '%a %U:%G' /dev/kvm)"; fi
elif [ -e /dev/kvm ]; then echo "/dev/kvm $(stat -c '%a %U:%G' /dev/kvm); no baseline record to compare"; fi
systemctl set-property --runtime ssh.service CPUWeight=100 MemoryLow=0 2>/dev/null && echo "ssh.service CPUWeight/MemoryLow reset"
echo "packages now: $(dpkg-query -W -f '${db:Status-Abbrev}\n' | grep -c '^ii') installed"
echo "== $(date -u +%FT%TZ) revert-root done"
