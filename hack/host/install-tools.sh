#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The tools hack/rerun-all.sh needs, for the OS user and without root: Go under ~/tools, kubectl and
# uv under ~/.local/bin, kind and ko under ~/go/bin. Versions from the environment. Idempotent.
#   hack/host/install-tools.sh
set -u
GO_VERSION="${GO_VERSION:-1.27.2}"; KUBECTL_VERSION="${KUBECTL_VERSION:-v1.37.1}"; KIND_VERSION="${KIND_VERSION:-v0.33.0}"; KO_VERSION="${KO_VERSION:-v0.19.1}"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
export PATH="$HOME/.local/bin:$HOME/tools/go/bin:$HOME/go/bin:$PATH"
mkdir -p "$HOME/tools" "$HOME/.local/bin" "$HOME/logs"
cd "$HOME/tools" || exit 1
[ -x go/bin/go ] || curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" | tar -xz || { echo "GO_FAILED"; exit 1; }
if [ ! -x "$HOME/.local/bin/kubectl" ]; then
  if ! curl -fsSLo "$HOME/.local/bin/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"; then echo "KUBECTL_FAILED"; exit 1; fi
  chmod +x "$HOME/.local/bin/kubectl"
fi
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh > "$HOME/logs/uv-install.log" 2>&1 || { echo "UV_FAILED"; exit 1; }
if ! { go install "sigs.k8s.io/kind@${KIND_VERSION}" > "$HOME/logs/go-install.log" 2>&1 && go install "github.com/google/ko@${KO_VERSION}" >> "$HOME/logs/go-install.log" 2>&1; }; then echo "GO_INSTALL_FAILED"; tail -3 "$HOME/logs/go-install.log"; exit 1; fi
echo "tools: go $(go version | awk '{print $3}') kind $(kind version 2>/dev/null | awk '{print $2}') ko $(ko version 2>/dev/null) kubectl $(kubectl version --client 2>/dev/null | awk '/Client/ {print $3}') uv $(uv --version 2>/dev/null | awk '{print $2}')"
echo "PATH needs: $HOME/.local/bin:$HOME/tools/go/bin:$HOME/go/bin"
