#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Root preparation of an Ubuntu host for hack/rerun-all.sh at density: docker and the few packages
# the scripts need, the OS user in the docker group, the kernel and docker limits a few thousand
# sandboxes need. Everything it changes is recorded under the user's ~/.gym-substrate-host/prep for
# hack/host/revert-root.sh. Idempotent. Restarts docker, so it refuses to run while kind runs.
#   sudo hack/host/prep-root.sh [USER]       (USER defaults to the sudo caller)
set -u
export DEBIAN_FRONTEND=noninteractive
U="${1:-${SUDO_USER:-}}"; [ -n "$U" ] || { echo "usage: prep-root.sh USER"; exit 2; }
H=$(getent passwd "$U" | cut -d: -f6); P="$H/.gym-substrate-host/prep"; mkdir -p "$P"
echo "== $(date -u +%FT%TZ) prep-root start for $U as $(id -un)"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^kind'; then echo "REFUSED: kind containers are running; docker would restart under them"; exit 2; fi
KEYS="fs.inotify.max_user_instances fs.inotify.max_user_watches net.ipv4.neigh.default.gc_thresh1 net.ipv4.neigh.default.gc_thresh2 net.ipv4.neigh.default.gc_thresh3 net.netfilter.nf_conntrack_max fs.aio-max-nr net.core.somaxconn net.ipv4.ip_local_port_range kernel.pid_max kernel.threads-max vm.max_map_count"
[ -s "$P/sysctl-before.txt" ] || for k in $KEYS; do printf '%s=%s\n' "$k" "$(sysctl -n "$k" 2>/dev/null | tr '\t' ' ')"; done > "$P/sysctl-before.txt"
[ -s "$P/pkgs-before.txt" ] || dpkg-query -W -f '${Package}\n' | sort > "$P/pkgs-before.txt"
echo "== packages"
apt-get update -qq > "$P/apt.log" 2>&1
if apt-get install -y -qq docker.io docker-buildx psmisc zstd jq make bzip2 rsync >> "$P/apt.log" 2>&1; then echo "apt ok"; else echo "APT_FAILED"; tail -5 "$P/apt.log"; exit 1; fi
dpkg-query -W -f '${Package}\n' | sort > "$P/pkgs-after.txt"
echo "packages added: $(comm -13 "$P/pkgs-before.txt" "$P/pkgs-after.txt" | tr '\n' ' ')"
systemctl enable --now docker >/dev/null 2>&1; echo "docker: $(docker --version) | $(docker buildx version 2>/dev/null | head -1)"
usermod -aG docker "$U" && echo "$U in the docker group"
echo "== limits"
# The neighbor table is global across network namespaces and its default ceiling of 1024 breaks
# near 1000 sandbox addresses; inotify is one budget per user; the rest are for thousands of
# sandbox processes (micro-VMs add a VMM and a virtiofsd each) and their connections.
cat > /etc/sysctl.d/91-gym-substrate.conf <<EOF
net.ipv4.neigh.default.gc_thresh1=4096
net.ipv4.neigh.default.gc_thresh2=16384
net.ipv4.neigh.default.gc_thresh3=32768
fs.inotify.max_user_instances=65536
fs.inotify.max_user_watches=4194304
fs.aio-max-nr=1048576
net.netfilter.nf_conntrack_max=2097152
net.ipv4.ip_local_port_range=10240 65000
net.core.somaxconn=65535
kernel.pid_max=4194304
vm.max_map_count=1048576
EOF
# threads-max defaults from the host's RAM; raise it only when it is below the pid ceiling.
[ "$(sysctl -n kernel.threads-max)" -lt 4194304 ] && echo 'kernel.threads-max=4194304' >> /etc/sysctl.d/91-gym-substrate.conf
sysctl --system > /dev/null 2>&1
echo "inotify instances $(sysctl -n fs.inotify.max_user_instances), neigh gc_thresh3 $(sysctl -n net.ipv4.neigh.default.gc_thresh3), pid_max $(sysctl -n kernel.pid_max), threads-max $(sysctl -n kernel.threads-max), max_map_count $(sysctl -n vm.max_map_count)"
printf '%s soft nofile 1048576\n%s hard nofile 1048576\n%s soft nproc unlimited\n' "$U" "$U" "$U" > /etc/security/limits.d/91-gym-substrate.conf
python3 - <<'PY'
import json, os
p = "/etc/docker/daemon.json"
d = json.load(open(p)) if os.path.exists(p) else {}
d["default-ulimits"] = {"nofile": {"Name": "nofile", "Hard": 1048576, "Soft": 1048576}}
json.dump(d, open(p, "w"), indent=2); print("daemon.json:", d)
PY
systemctl restart docker && sleep 3 && docker info >/dev/null 2>&1 && echo "docker restarted"
echo "thp: enabled $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null) shmem $(cat /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null) (not changed)"
if [ -e /dev/kvm ]; then
  if docker pull -q alpine >/dev/null 2>&1 && docker run --rm --device /dev/kvm alpine true >/dev/null 2>&1; then echo "kvm: docker can use /dev/kvm"; else echo "kvm: present but docker cannot use it"; fi
else echo "kvm: no /dev/kvm (gvisor only)"; fi
if docker pull -q registry.k8s.io/pause:3.10 >/dev/null 2>&1; then echo "docker egress ok"; else echo "docker egress FAILED"; fi
chown -R "$U:$U" "$H/.gym-substrate-host"
echo "== $(date -u +%FT%TZ) prep-root done; log out and in again for the docker group"
