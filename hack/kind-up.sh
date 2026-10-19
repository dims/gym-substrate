#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Substrate on a kind cluster, ready for the Gym provider: the install, the sandbox class
# (the 64 KiB gVisor asset when the host needs it, or the micro-VM assets and SandboxConfig),
# the router settings, NodePorts, the demo pools and the gym WorkerPools. Steps that are
# already done are skipped.
#   hack/kind-up.sh
# Environment: WORK, SUBSTRATE_DIR (default WORK/substrate), SUBSTRATE_REF (default
# upstream/main), RUNTIME (gvisor or microvm), GVISOR_ASSET_DIR (required on a 64 KiB-page
# kernel with gvisor), MICROVM_ASSET_DIR (a set made by Substrate's
# hack/microvm-assets/assemble.sh; downloaded when unset), POST_KIND_HOOK (a script run once
# the cluster exists, for a host firewall), POOL_REPLICAS / POOL_CPU / POOL_MEMORY (default
# 3 / 6 / 12Gi; with worker nodes, one pool of POOL_REPLICAS pinned to each worker node).
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

step "sandbox class $RUNTIME"
if [ "$RUNTIME" = microvm ]; then
  docker exec kind-control-plane test -e /dev/kvm || fail KVM "the kind nodes have no /dev/kvm; the cluster must be created on a host where docker can use the device"
  if kubectl get sandboxconfig microvm >/dev/null 2>&1; then
    echo "microvm SandboxConfig present"
  else
    # install-microvm-deps.sh assembles the asset set into OUT unless a current one is there,
    # stages it into the install's rustfs bucket and applies the SandboxConfig.
    HOST_ARCH=$(arch)
    (
      export ATE_INSTALL_KIND=true NO_DEV_ENV=true KUBECTL_CONTEXT=kind-kind BUCKET_NAME="${BUCKET_NAME:-ate-snapshots}" ARCH="$HOST_ARCH"
      [ -z "${MICROVM_ASSET_DIR:-}" ] || export OUT="$MICROVM_ASSET_DIR"
      hack/install-microvm-deps.sh --install
    ) > "$LOG_DIR/microvm-deps.log" 2>&1 || { tail -15 "$LOG_DIR/microvm-deps.log"; fail MICROVM_DEPS; }
  fi
  echo "microvm SandboxConfig version $(kubectl get sandboxconfig microvm -o jsonpath='{.spec.defaultVersion}'), $(arch) assets; kvm nodes: $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.capacity.ate\.dev/kvm} {end}')"
elif [ "$(getconf PAGESIZE)" = 65536 ]; then
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
bash "$REPO/hack/kind-api-access.sh" >/dev/null || fail API_HOST_ACCESS
NODE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' kind-control-plane); printf '%s' "$NODE_IP" > "$RUN_DIR/node-ip"
A=000; R=000
for _ in $(seq 1 12); do
  A=$(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://$NODE_IP:30443/"); R=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$NODE_IP:30080/")
  [ "$A" != 000 ] && [ "$R" != 000 ] && break
  sleep 5
done
if [ "$A" = 000 ] || [ "$R" = 000 ]; then fail NODEPORTS "api $A router $R after 60 s"; fi
echo "node ip $NODE_IP; api np https $A, router np http $R, prometheus np http $(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$NODE_IP:30090/-/ready")"

step "demo pools and gym pools"
# The demo of each class carries the install's worker image for that class; the gym pools
# reuse it. The micro-VM demo also builds a golden snapshot, so its success means a guest
# booted, checkpointed and restored on this host.
if kubectl get workerpool -n ate-demo-sandbox sandbox-workerpool >/dev/null 2>&1; then
  echo "demo sandbox present"
else
  hack/install-ate-kind.sh --deploy-demo-sandbox > "$LOG_DIR/demo-sandbox.log" 2>&1 || { tail -10 "$LOG_DIR/demo-sandbox.log"; fail DEMO_SANDBOX; }
fi
if [ "$RUNTIME" = microvm ]; then
  if kubectl get workerpool -n ate-demo-counter-microvm counter-microvm >/dev/null 2>&1; then
    echo "demo counter-microvm present"
  else
    hack/install-ate-kind.sh --deploy-demo-counter-microvm > "$LOG_DIR/demo-counter-microvm.log" 2>&1 || { tail -15 "$LOG_DIR/demo-counter-microvm.log"; fail DEMO_COUNTER_MICROVM; }
    echo "demo counter-microvm golden: $(kubectl ate get actor-templates -a ate-demo-counter-microvm 2>/dev/null | awk 'NR>1 {print $3}' | head -1)"
  fi
  WI=$(kubectl get workerpool -n ate-demo-counter-microvm counter-microvm -o jsonpath='{.spec.workerImage}')
else
  WI=$(kubectl get workerpool -n ate-demo-sandbox sandbox-workerpool -o jsonpath='{.spec.workerImage}')
fi
[ -n "$WI" ] || fail WORKER_IMAGE
# A micro-VM worker's memory request equals its limit: the guest RAM plus the VMM reserve has
# to be there. A gVisor worker's actors page in what they touch.
if [ "$RUNTIME" = microvm ]; then POOL_MEMORY_REQUEST="$POOL_MEMORY"; else POOL_MEMORY_REQUEST="${POOL_MEMORY_REQUEST:-$POOL_MEMORY}"; fi
render_pool() { # render_pool NAME [NODE]
  cat <<POOL
apiVersion: ate.dev/v1alpha1
kind: WorkerPool
metadata:
  name: $1
  namespace: ate-demo-sandbox
  labels:
    workload: gym
spec:
  replicas: $POOL_REPLICAS
  sandboxClasses:
  - name: $RUNTIME
  template:
${2:+    nodeSelector:
      kubernetes.io/hostname: $2
}    resources:
      limits:
        cpu: "$POOL_CPU"
        memory: $POOL_MEMORY
      requests:
        cpu: "1"
        memory: $POOL_MEMORY_REQUEST
  workerImage: $WI
POOL
}
WORKER_NODES=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}')
POOLS="$RUN_DIR/gym-workerpools.yaml"; : > "$POOLS"; n_pools=0
if [ -n "$WORKER_NODES" ]; then
  for n in $WORKER_NODES; do n_pools=$((n_pools + 1)); render_pool "gym-workerpool-$n_pools" "$n" >> "$POOLS"; echo "---" >> "$POOLS"; done
  echo "gym pools: $n_pools, one per worker node, $POOL_REPLICAS workers each"
else
  render_pool gym-workerpool >> "$POOLS"; n_pools=1
fi
kubectl apply -f "$POOLS" >/dev/null || fail GYM_POOL
WANT=$((POOL_REPLICAS * n_pools))
active_workers() { [ "$(kubectl ate get workers 2>/dev/null | awk '$2 ~ /^gym-workerpool/ && $3=="WORKER_STATE_ACTIVE"' | wc -l | tr -d ' ')" -ge "$WANT" ]; }
wait_for 600 "gym workers" active_workers || { kubectl get pods -n ate-demo-sandbox; fail GYM_POOL_WORKERS; }
echo "gym workers active: $(kubectl ate get workers | awk '$2 ~ /^gym-workerpool/ && $3=="WORKER_STATE_ACTIVE"' | wc -l | tr -d ' ') of $WANT ($RUNTIME, cpu $POOL_CPU / $POOL_MEMORY each)"
step "kind-up done"
