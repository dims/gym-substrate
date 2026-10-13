#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Substrate on a one-node kind cluster, ready for the Gym provider: the install, the 64 KiB
# gVisor asset when the host needs it, the router settings, NodePorts, the demo sandbox and
# the gym WorkerPool. Steps that are already done are skipped.
#   hack/kind-up.sh
# Environment: WORK, SUBSTRATE_DIR (default WORK/substrate), SUBSTRATE_REF (default
# upstream/main), GVISOR_ASSET_DIR (required on a 64 KiB-page kernel), POST_KIND_HOOK (a script
# run once the cluster exists, for a host firewall), POOL_REPLICAS / POOL_CPU / POOL_MEMORY
# (default 3 / 6 / 12Gi).
set -uo pipefail
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/_lib.sh"
SUBSTRATE_DIR="${SUBSTRATE_DIR:-$WORK/substrate}"; SUBSTRATE_REF="${SUBSTRATE_REF:-upstream/main}"
POOL_REPLICAS="${POOL_REPLICAS:-3}"; POOL_CPU="${POOL_CPU:-6}"; POOL_MEMORY="${POOL_MEMORY:-12Gi}"

step "substrate at $SUBSTRATE_REF"
if [ ! -d "$SUBSTRATE_DIR/.git" ]; then
  git clone -q https://github.com/agent-substrate/substrate.git "$SUBSTRATE_DIR" || fail CLONE
  git -C "$SUBSTRATE_DIR" remote rename origin upstream
fi
git -C "$SUBSTRATE_DIR" fetch -q upstream || fail FETCH
git -C "$SUBSTRATE_DIR" checkout -q --detach "$SUBSTRATE_REF" || fail CHECKOUT "$SUBSTRATE_REF"
echo "substrate at $(git -C "$SUBSTRATE_DIR" log -1 --format='%h %s')"
(cd "$SUBSTRATE_DIR" && go build -o "$BIN_DIR/kubectl-ate" ./cmd/kubectl-ate) || fail KUBECTL_ATE_BUILD
echo "kubectl-ate built into $BIN_DIR"
cd "$SUBSTRATE_DIR" || exit 1

step "kind cluster"
if kind get clusters 2>/dev/null | grep -qx kind; then
  echo "kind cluster exists"
else
  hack/create-kind-cluster.sh > "$LOG_DIR/kind-create.log" 2>&1 || { tail -20 "$LOG_DIR/kind-create.log"; fail KIND_CREATE; }
fi
kubectl get nodes -o wide --no-headers | awk '{print "node", $1, $2, $5, $6}'
if [ -n "${POST_KIND_HOOK:-}" ]; then
  bash "$POST_KIND_HOOK" > "$LOG_DIR/post-kind-hook.log" 2>&1 || { tail -10 "$LOG_DIR/post-kind-hook.log"; fail POST_KIND_HOOK; }
  echo "post-kind hook ok: $POST_KIND_HOOK"
fi
docker exec kind-control-plane crictl pull registry.k8s.io/pause:3.10 >/dev/null 2>&1 || fail NODE_EGRESS "the kind node cannot pull from registry.k8s.io; let the kind bridge forward (POST_KIND_HOOK)"
echo "node egress ok"

step "ate-system"
if kubectl -n ate-system get deploy ate-api-server >/dev/null 2>&1; then
  echo "ate-system present"
else
  hack/install-ate-kind.sh --deploy-ate-system --credential-provider='{"name":"k8s.io"}' > "$LOG_DIR/install.log" 2>&1 || { tail -30 "$LOG_DIR/install.log"; fail INSTALL; }
fi
kubectl -n ate-system wait --for=condition=Available deploy --all --timeout=600s >/dev/null || { kubectl -n ate-system get pods; fail ATE_SYSTEM_PODS; }
pods_settled() { [ -z "$(kubectl -n ate-system get pods --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed"')" ]; }
wait_for 300 "ate-system pods" pods_settled || { kubectl -n ate-system get pods; fail ATE_SYSTEM_PODS; }
echo "ate-system pods: $(kubectl -n ate-system get pods --no-headers | awk '$3=="Running"' | wc -l | tr -d ' ') running, $(kubectl -n ate-system get pods --no-headers | awk '$3=="Completed"' | wc -l | tr -d ' ') completed"

step "gvisor asset"
if [ "$(getconf PAGESIZE)" = 65536 ]; then
  [ -n "${GVISOR_ASSET_DIR:-}" ] || fail GVISOR_ASSET "64 KiB pages: set GVISOR_ASSET_DIR to a runsc build made with --define=pagesize=64k (gvisor.tar.zstd and its .sha256)"
  bash "$REPO/hack/gvisor-asset.sh" "$GVISOR_ASSET_DIR" > "$LOG_DIR/gvisor-asset.log" 2>&1 || { tail -10 "$LOG_DIR/gvisor-asset.log"; fail GVISOR_ASSET; }
  tail -1 "$LOG_DIR/gvisor-asset.log"
else
  echo "page size $(getconf PAGESIZE): stock gVisor asset"
fi

step "router"
if kubectl -n ate-system get deploy atenet-router -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- "--parked-request-budget"; then
  echo "router args present"
else
  kubectl -n ate-system patch deploy atenet-router --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--route-timeout=30m30s"},{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--parked-request-budget=10m"},{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--extproc-max-requests=8192"}]' >/dev/null || fail ROUTER_PATCH
  kubectl -n ate-system rollout status deploy/atenet-router --timeout=300s >/dev/null || fail ROUTER_ROLLOUT
fi
echo "router args: $(kubectl -n ate-system get deploy atenet-router -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -E 'route-timeout|parked|extproc' | tr -d '"[]' | tr '\n' ' ')"

step "nodeports"
kubectl apply -f "$REPO/manifests/nodeports.yaml" >/dev/null || fail NODEPORTS
NODE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' kind-control-plane); printf '%s' "$NODE_IP" > "$RUN_DIR/node-ip"
A=000; R=000
for _ in $(seq 1 12); do
  A=$(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://$NODE_IP:30443/"); R=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$NODE_IP:30080/")
  [ "$A" != 000 ] && [ "$R" != 000 ] && break
  sleep 5
done
[ "$A" != 000 ] && [ "$R" != 000 ] || fail NODEPORTS "api $A router $R after 60 s"
echo "node ip $NODE_IP; api np https $A, router np http $R"

step "demo sandbox and gym pool"
if kubectl get workerpool -n ate-demo-sandbox sandbox-workerpool >/dev/null 2>&1; then
  echo "demo sandbox present"
else
  hack/install-ate-kind.sh --deploy-demo-sandbox > "$LOG_DIR/demo-sandbox.log" 2>&1 || { tail -10 "$LOG_DIR/demo-sandbox.log"; fail DEMO_SANDBOX; }
fi
WI=$(kubectl get workerpool -n ate-demo-sandbox sandbox-workerpool -o jsonpath='{.spec.workerImage}'); [ -n "$WI" ] || fail WORKER_IMAGE
sed -e "s#WORKER_IMAGE#$WI#" -e "s/replicas: .*/replicas: $POOL_REPLICAS/" -e "s/cpu: \"8\"/cpu: \"$POOL_CPU\"/" -e "s/memory: 32Gi/memory: $POOL_MEMORY/" -e "s/memory: 16Gi/memory: $POOL_MEMORY/" "$REPO/manifests/gym-workerpool.yaml" | kubectl apply -f - >/dev/null || fail GYM_POOL
active_workers() { [ "$(kubectl ate get workers 2>/dev/null | awk '$2 ~ /^gym-workerpool/ && $3=="WORKER_STATE_ACTIVE"' | wc -l | tr -d ' ')" -ge "$POOL_REPLICAS" ]; }
wait_for 300 "gym workers" active_workers || { kubectl get pods -n ate-demo-sandbox; fail GYM_POOL_WORKERS; }
echo "gym workers active: $(kubectl ate get workers | awk '$2 ~ /^gym-workerpool/ && $3=="WORKER_STATE_ACTIVE"' | wc -l | tr -d ' ') of $POOL_REPLICAS (cpu $POOL_CPU / $POOL_MEMORY each)"
step "kind-up done"
