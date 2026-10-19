#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Creates one ActorTemplate per workload image for the NeMo Gym Substrate
# provider. The image runs untouched; this directory's sandbox server is
# mounted from an image volume and set as the container command.
#
#   BUCKET_NAME=<snapshot bucket> hack/gym-templates.sh IMAGE...
#
#   ATESPACE        templates go here (default nemo-gym); created if missing
#   WORKLOAD        WorkerPool label the templates select (default sandbox)
#   ACTOR_CPU       cpu limit per actor (default 1); with ACTOR_MEMORY this
#   ACTOR_MEMORY    memory limit per actor (default 1Gi); sets how many
#                   actors share one worker, so size both against the pool
#   AGENT_IMAGE     digest-pinned sandbox server image (default: ko build,
#                   which needs KO_DOCKER_REPO)
#   WAIT_GOLDEN     set to wait until every template named here has a golden
#                   snapshot (WAIT_GOLDEN_TIMEOUT seconds, default 600)
#
# Pass each image as NeMo Gym will ask for it. The template name is derived
# from the image string after dropping a docker:// or oci:// scheme and a
# docker.io/ registry, the same way the provider's unit-tested
# template_name_for_image does.
set -o errexit -o nounset -o pipefail
cd "$(dirname "$0")/.." || exit 1

: "${BUCKET_NAME:?set BUCKET_NAME to the snapshot bucket}"
ATESPACE="${ATESPACE:-nemo-gym}"
WORKLOAD="${WORKLOAD:-sandbox}"
ACTOR_CPU="${ACTOR_CPU:-1}"
ACTOR_MEMORY="${ACTOR_MEMORY:-1Gi}"

# This module has no go-containerregistry dependency, so the version is pinned here.
CRANE_VERSION="${CRANE_VERSION:-v0.21.7}"
crane() {
  go run "github.com/google/go-containerregistry/cmd/crane@${CRANE_VERSION}" "$@"
}

# ko builds linux/amd64 unless told otherwise; the agent must match the nodes.
NODE_ARCH="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')"
export KO_DEFAULTPLATFORMS="${KO_DEFAULTPLATFORMS:-linux/${NODE_ARCH}}"

kubectl ate get atespaces "${ATESPACE}" >/dev/null 2>&1 || kubectl ate create atespace "${ATESPACE}"

names=()

for image in "$@"; do
  ref="${image#docker://}"
  ref="${ref#oci://}"
  ref="${ref#docker.io/}"
  name="swb-$(printf %s "${ref}" | shasum -a 256 | cut -c1-16)"
  names+=("${name}")
  pinned="${ref%%@*}@$(crane digest "${ref}")"
  if existing="$(kubectl ate get actor-template "${name}" -a "${ATESPACE}" -o yaml 2>/dev/null)"; then
    if grep -q "image: ${pinned}\$" <<<"${existing}"; then
      echo "${ATESPACE}/${name} already serves ${pinned}"
    else
      echo "warning: ${ATESPACE}/${name} serves an older digest of ${ref}; delete it to pick up ${pinned}" >&2
    fi
    continue
  fi
  if [ -z "${AGENT_IMAGE:-}" ]; then
    AGENT_IMAGE="$(ko build --base-import-paths ./cmd/sandbox-agent)"
    echo "agent image ${AGENT_IMAGE} ($(crane config "${AGENT_IMAGE}" | python3 -c 'import json, sys; c = json.load(sys.stdin); print(c["os"], c["architecture"])'))"
  fi
  kubectl ate create actor-template -f - <<MANIFEST
metadata:
  atespace: ${ATESPACE}
  name: ${name}
workerSelector:
  matchLabels:
    workload: ${WORKLOAD}
containers:
- name: sandbox
  image: ${pinned}
  command: ["/ate/ko-app/sandbox-agent"]
  env:
  - name: PORT
    value: "80"
  wakeupProbe:
    httpGet:
      path: /readyz
      port: 80
    timeoutSeconds: 120
  volumeMounts:
  - name: agent
    mountPath: /ate
volumes:
- name: agent
  image:
    reference: ${AGENT_IMAGE}
resources:
  limits:
  - name: cpu
    quantity: "${ACTOR_CPU}"
  - name: memory
    quantity: ${ACTOR_MEMORY}
snapshotConfig:
  preferredFidelity: SNAPSHOT_FIDELITY_MEMORY
  storageLocation: gs://${BUCKET_NAME}/${ATESPACE}/
MANIFEST
  echo "${ATESPACE}/${name} serves ${ref}"
done

if [ -n "${WAIT_GOLDEN:-}" ] && [ "${#names[@]}" -gt 0 ]; then
  deadline=$((SECONDS + ${WAIT_GOLDEN_TIMEOUT:-600}))
  while :; do
    ready=0
    for n in "${names[@]}"; do
      # The golden tag is a UUID in whichever column the listing puts it (the sandbox-class column went away with Substrate #2780).
      [ -n "$(kubectl ate get actor-template "${n}" -a "${ATESPACE}" 2>/dev/null | awk 'NR>1 && / [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}( |$)/')" ] && ready=$((ready + 1))
    done
    if [ "${ready}" -eq "${#names[@]}" ]; then echo "all templates have a golden (${ready})"; break; fi
    if [ "${SECONDS}" -ge "${deadline}" ]; then
      kubectl ate get actor-template -a "${ATESPACE}"
      echo "GOLDEN_WAIT_FAILED: ${ready} of ${#names[@]} templates have a golden" >&2; exit 1
    fi
    sleep 5
  done
fi
