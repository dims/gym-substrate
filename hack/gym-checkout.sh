#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# A Gym checkout with the pull requests the provider needs, the plugin added to its project,
# and the provider configs for this cluster.
#   hack/gym-checkout.sh
# Environment: WORK, GYM_DIR (default WORK/gym), GYM_REF (default upstream/main), GYM_BRANCHES
# (dims/Nemo-Gym branches merged on top; default: the four open pull requests),
# GYM_SUBSTRATE_SOURCE (a directory or a git URL for the plugin; default this repository's main),
# REPLAY_URL (default http://127.0.0.1:9797, written to env.yaml).
set -uo pipefail
# shellcheck source=hack/_lib.sh
. "$(dirname "$0")/_lib.sh"
GYM_DIR="${GYM_DIR:-$WORK/gym}"; GYM_REF="${GYM_REF:-upstream/main}"
GYM_BRANCHES="${GYM_BRANCHES:-config-atomic-write abort-dead-sandbox litellm-replay-fields plugin-server-deps}"
GYM_SUBSTRATE_SOURCE="${GYM_SUBSTRATE_SOURCE:-git+https://github.com/dims/gym-substrate}"
REPLAY_URL="${REPLAY_URL:-http://127.0.0.1:9797}"
NODE_IP=$(node_ip); [ -n "$NODE_IP" ] || fail NODE_IP "no $RUN_DIR/node-ip; run hack/kind-up.sh first"

step "gym checkout at $GYM_REF"
if [ ! -d "$GYM_DIR/.git" ]; then
  git clone -q https://github.com/NVIDIA-NeMo/Gym.git "$GYM_DIR" || fail GYM_CLONE
  git -C "$GYM_DIR" remote rename origin upstream
fi
cd "$GYM_DIR" || exit 1
git remote get-url dims >/dev/null 2>&1 || git remote add dims https://github.com/dims/Nemo-Gym.git
git fetch -q upstream main || fail GYM_FETCH upstream
# shellcheck disable=SC2086
[ -z "$GYM_BRANCHES" ] || git fetch -q dims $GYM_BRANCHES || fail GYM_FETCH dims
git reset -q --hard
git checkout -q -B from-zero "$GYM_REF" || fail GYM_CHECKOUT "$GYM_REF"
echo "gym base: $(git log -1 --format='%h %s' "$GYM_REF")"
for b in $GYM_BRANCHES; do
  if git -c user.name=gym-substrate -c user.email=gym-substrate@localhost merge -q --no-edit "dims/$b" >/dev/null 2>&1; then
    echo "merged $b"
  else
    conflicts=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
    git merge --abort 2>/dev/null; fail GYM_MERGE "$b does not merge onto $GYM_REF (conflicts: ${conflicts:-none reported}); rebase the branch or drop it from GYM_BRANCHES"
  fi
done
echo "gym head: $(git log -1 --format=%h), $(git log --oneline "$GYM_REF"..HEAD | wc -l | tr -d ' ') commits over the base"

step "venv and plugin from $GYM_SUBSTRATE_SOURCE"
if [ -d "$GYM_SUBSTRATE_SOURCE" ]; then
  uv add -q "$(cd "$GYM_SUBSTRATE_SOURCE" && pwd)" > "$LOG_DIR/uv-add.log" 2>&1 || { tail -10 "$LOG_DIR/uv-add.log"; fail UV_ADD; }
else
  uv add -q "gym-substrate @ $GYM_SUBSTRATE_SOURCE" > "$LOG_DIR/uv-add.log" 2>&1 || { tail -10 "$LOG_DIR/uv-add.log"; fail UV_ADD; }
fi
uv sync -q --extra dev --extra sandbox --extra ray > "$LOG_DIR/uv-sync.log" 2>&1 || { tail -10 "$LOG_DIR/uv-sync.log"; fail UV_SYNC; }
(cd /tmp && "$GYM_DIR/.venv/bin/python" -c "import importlib.metadata as m, nemo_gym; from nemo_gym.sandbox.providers.registry import get_provider_class; print('provider resolves:', get_provider_class('substrate').__module__, 'gym-substrate', m.version('gym-substrate'), 'nemo_gym from', nemo_gym.__file__)") || fail PLUGIN_RESOLVE

step "env.yaml and provider configs"
[ -f env.yaml ] || printf 'policy_base_url: %s/v1\npolicy_api_key: replay\npolicy_model_name: replay\n' "$REPLAY_URL" > env.yaml
echo "env.yaml: $(tr '\n' ' ' < env.yaml)"
SRC_CFG=$(.venv/bin/python -c "import gym_substrate, pathlib; print(pathlib.Path(gym_substrate.__file__).parent / 'configs' / 'substrate.yaml')") || fail CONFIG
sed -E -e "s#ateapi_addr: .*#ateapi_addr: $NODE_IP:30443#" -e "s#atenet_addr: .*#atenet_addr: $NODE_IP:30080#" "$SRC_CFG" > "$RUN_DIR/substrate.yaml"
sed -E 's/suspend_policy: .*/suspend_policy: never/' "$RUN_DIR/substrate.yaml" > "$RUN_DIR/substrate-never.yaml"
echo "configs: $(grep -E 'ateapi_addr|atenet_addr|suspend_policy' "$RUN_DIR/substrate.yaml" | tr -s ' ' | tr '\n' ';')"
# The agent server builds its own venv from its requirements.txt, where litellm floats:
# 1.106.0 (2026-10-18) imports CacheableResult from mcp 2 and nemo-gym pins mcp<2. Pin it in
# this checkout (a local edit, like the plugin in pyproject.toml); the head venv follows the lock.
REQ=responses_api_agents/mini_swe_agent_2/requirements.txt
grep -q '^litellm' "$REQ" || echo 'litellm<1.106' >> "$REQ"
echo "agent server pins: $(grep -E '^(litellm|mini-swe-agent|swebench)' "$REQ" | tr '\n' ' ')"
step "gym-checkout done"
