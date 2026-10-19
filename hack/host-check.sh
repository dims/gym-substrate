#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Checks a host before hack/rerun-all.sh and changes nothing. Exit 1 on any FAIL.
set -uo pipefail
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/_lib.sh"
fails=0
pass() { echo "PASS $*"; }
failed() { echo "FAIL $*"; fails=$((fails + 1)); }
ver() {
  case "$1" in
    go) go version ;; kubectl) kubectl version --client 2>/dev/null ;; ko) ko version ;; kind) kind version ;;
    fuser) echo psmisc ;; sha256sum) sha256sum --version ;; shasum) shasum --version ;; *) "$1" --version 2>/dev/null ;;
  esac | head -1
}
echo "info arch $(arch), page size $(getconf PAGESIZE), kvm $([ -e /dev/kvm ] && echo yes || echo no), $(nproc) cpus, $(free -g | awk '/Mem:/{print $2}') GiB, $(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -d ' ' || df -BG --output=avail / | tail -1 | tr -d ' ') free for docker"
for t in docker kind kubectl go ko uv zstd fuser python3 jq curl git sha256sum shasum; do
  if command -v "$t" >/dev/null 2>&1; then pass "$t: $(ver "$t")"; else failed "$t missing"; fi
done
if docker info >/dev/null 2>&1; then pass "docker daemon"; else failed "docker daemon not reachable"; fi
if docker buildx version >/dev/null 2>&1; then pass "docker buildx: $(docker buildx version | head -1)"; else failed "docker buildx missing (ate-setup builds envoy-dataplane with it)"; fi
# wget exits 1 on the 401 and the pipeline would fail under pipefail, so read its headers first.
egress=$(docker pull -q alpine >/dev/null 2>&1 && docker run --rm alpine wget -q -S -O /dev/null --timeout=15 https://registry.k8s.io/v2/ 2>&1)
if grep -q " 401 " <<<"$egress"; then
  pass "container egress to registry.k8s.io"
else
  failed "container egress: a container cannot reach registry.k8s.io (firewall or proxy): $(head -1 <<<"$egress")"
fi
if [ "$RUNTIME" = microvm ]; then
  if docker run --rm --device /dev/kvm alpine true >/dev/null 2>&1; then pass "kvm: docker can use /dev/kvm"; else failed "kvm: docker cannot use /dev/kvm (RUNTIME=microvm needs it: a KVM host and a readable device)"; fi
  echo "info kernel.pid_max $(sysctl -n kernel.pid_max), kernel.threads-max $(sysctl -n kernel.threads-max), vm.max_map_count $(sysctl -n vm.max_map_count), fs.file-max $(sysctl -n fs.file-max), thp $(tr -d '\n' < /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null) shmem $(tr -d '\n' < /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null)"
fi
inst=$(sysctl -n fs.inotify.max_user_instances); watches=$(sysctl -n fs.inotify.max_user_watches)
if [ "$inst" -ge 8192 ]; then pass "fs.inotify.max_user_instances $inst"; else failed "fs.inotify.max_user_instances $inst (< 8192; the default 128 breaks fleets above about 64 sandboxes)"; fi
if [ "$watches" -ge 1048576 ]; then pass "fs.inotify.max_user_watches $watches"; else failed "fs.inotify.max_user_watches $watches (< 1048576)"; fi
for p in 5001 8080 8000; do
  owner=$(ss -ltnp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {print $NF}' | head -1)
  [ -n "$owner" ] && echo "info port $p in use by $owner" || echo "info port $p free"
done
if [ "$fails" -eq 0 ]; then echo "host-check ok"; else echo "host-check: $fails failures"; exit 1; fi
