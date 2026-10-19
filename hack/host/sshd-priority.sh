#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Keep sshd responsive while thousands of sandboxes saturate the host (runtime only; a reboot or
# `reset` undoes it). Both operator sessions were locked out for 7 minutes at load 1000 once.
#   sudo hack/host/sshd-priority.sh [reset]
set -u
if [ "${1:-}" = reset ]; then systemctl set-property --runtime ssh.service CPUWeight=100 MemoryLow=0
else systemctl set-property --runtime ssh.service CPUWeight=10000 MemoryLow=128M; fi
systemctl show ssh.service -p CPUWeight -p MemoryLow -p ActiveState | tr '\n' ' '; echo
