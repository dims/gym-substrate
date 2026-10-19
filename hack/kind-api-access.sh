#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Allow the Linux host to reach the API NodePort without admitting other pods.
set -euo pipefail
# The whole IPv4 subnet of Docker's kind network, not only its gateway: a NodePort request that
# kube-proxy forwards to a pod on another node arrives with the node's address as its source.
KIND_CIDR=$(docker network inspect kind --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' | awk '/^[0-9]+\./ {print; exit}')
[ -n "$KIND_CIDR" ] || { echo "no IPv4 subnet on Docker's kind network" >&2; exit 1; }

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
        cidr: ${KIND_CIDR}
    ports:
    - protocol: TCP
      port: 443
YAML
