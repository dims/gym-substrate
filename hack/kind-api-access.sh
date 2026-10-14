#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Allow the Linux host to reach the API NodePort without admitting other pods.
set -euo pipefail
HOST_IP=$(docker network inspect kind --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' | awk '/^[0-9]+\./ {print; exit}')
[ -n "$HOST_IP" ] || { echo "no IPv4 gateway on Docker's kind network" >&2; exit 1; }

kubectl apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: gym-host-api-access
  namespace: ate-system
spec:
  podSelector:
    matchLabels:
      app: ate-api-server
  policyTypes:
  - Ingress
  ingress:
  - from:
    - ipBlock:
        cidr: ${HOST_IP}/32
    ports:
    - protocol: TCP
      port: 443
YAML
