#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Upload a gVisor release tarball into the install's object store and point the gvisor-default
# SandboxConfig's default version at it for one architecture. Needed on a 64 KiB-page kernel,
# where the released assets fail at runsc start. Create templates after this: a template
# created before the swap never gets a golden snapshot.
#   hack/gvisor-asset.sh ASSET_DIR [ARCH]
# ASSET_DIR holds gvisor.tar.zstd and gvisor.tar.zstd.sha256.
set -uo pipefail
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/_lib.sh"
ASSET_DIR=${1:?asset dir with gvisor.tar.zstd and its .sha256}; ARCH=${2:-$(arch)}
TAR="$ASSET_DIR/gvisor.tar.zstd"
SHA=$(cut -d' ' -f1 "$TAR.sha256" 2>/dev/null)
[ -n "$SHA" ] || fail ASSET_SHA "no $TAR.sha256"
echo "$SHA  $TAR" | sha256sum -c - >/dev/null || fail ASSET_SHA "sha256 mismatch for $TAR"
# Backend and credentials from ate-api-server's object-store plugin container (the one whose
# env names ATE_STORAGE_BACKEND), literal or secretKeyRef.
eval "$(kubectl -n ate-system get deploy ate-api-server -o json | python3 -c '
import base64, json, subprocess, sys
spec = json.load(sys.stdin)["spec"]["template"]["spec"]
containers = spec.get("initContainers", []) + spec["containers"]
plugins = [c for c in containers if any(e["name"] == "ATE_STORAGE_BACKEND" for e in c.get("env", []))]
if not plugins:
    sys.exit("no container of ate-api-server sets ATE_STORAGE_BACKEND")
for e in plugins[0]["env"]:
    n = e["name"]
    if n not in ("ATE_STORAGE_BACKEND", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"):
        continue
    if "value" in e:
        v = e["value"]
    else:
        r = e["valueFrom"]["secretKeyRef"]
        raw = subprocess.check_output(["kubectl", "-n", "ate-system", "get", "secret", r["name"], "-o", "jsonpath={.data." + r["key"] + "}"])
        v = base64.b64decode(raw).decode()
    print("export %s=%s" % (n, json.dumps(v)))
')" || fail ASSET_ENV "cannot read the snapshot-plugin env"
BUCKET="${BUCKET_NAME:-ate-snapshots}"; KEY="gvisor-assets/$SHA/gvisor.tar.zstd"
case "${ATE_STORAGE_BACKEND:-}" in
  s3)
    kubectl -n ate-system port-forward svc/rustfs 9000:9000 >/dev/null 2>&1 & PF=$!
    trap 'kill $PF 2>/dev/null' EXIT
    sleep 2
    uv run --no-project --with boto3 python "$REPO/hack/s3put.py" "$TAR" "$BUCKET" "$KEY" http://127.0.0.1:9000 || fail ASSET_UPLOAD
    URL="s3://$BUCKET/$KEY" ;;
  gcs)
    gcloud storage cp "$TAR" "gs://$BUCKET/$KEY" >/dev/null || fail ASSET_UPLOAD
    URL="gs://$BUCKET/$KEY" ;;
  *) fail ASSET_BACKEND "ATE_STORAGE_BACKEND is '${ATE_STORAGE_BACKEND:-}', not s3 or gcs" ;;
esac
PATCH=$(kubectl get sandboxconfig gvisor-default -o json | python3 -c '
import json, sys
arch, url, sha = sys.argv[1:4]
spec = json.load(sys.stdin)["spec"]
idx = [v["name"] for v in spec["versions"]].index(spec["defaultVersion"])
if arch in spec["versions"][idx].get("assets", {}):
    print(json.dumps([{"op": "add", "path": f"/spec/versions/{idx}/assets/{arch}/gvisor", "value": {"url": url, "sha256": sha}}]))
else:
    print(json.dumps([{"op": "add", "path": f"/spec/versions/{idx}/assets/{arch}", "value": {"gvisor": {"url": url, "sha256": sha}}}]))
' "$ARCH" "$URL" "$SHA") || fail ASSET_PATCH
kubectl patch sandboxconfig gvisor-default --type=json -p="$PATCH" >/dev/null || fail ASSET_PATCH
echo "gvisor-default $(kubectl get sandboxconfig gvisor-default -o jsonpath='{.spec.defaultVersion}') $ARCH sha ${SHA:0:8} $URL"
