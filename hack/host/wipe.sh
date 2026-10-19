#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# End of a borrowed host, as the OS user, after the records have been copied off it.
#   hack/host/wipe.sh plan    print what wipe would remove and what it keeps; changes nothing
#   hack/host/wipe.sh stop    end our processes and the kind cluster
#   hack/host/wipe.sh wipe    stop, then remove everything of ours from the home directory and /tmp
# What is ours: WORK (default ~/gym-substrate-run), the tools of hack/host/install-tools.sh, the
# caches they made, EXTRA_DIRS (space separated, such as a bundle directory), and every home entry
# that was not there when hack/host/baseline.sh --save ran. Entries of the baseline stay. ~/.ssh
# stays too: remove it by hand as the last command once the final check has passed. Then
# hack/host/revert-root.sh. Never run wipe without reading plan first.
set -u
MODE=${1:-plan}; WORK="${WORK:-$HOME/gym-substrate-run}"; EXTRA_DIRS="${EXTRA_DIRS:-}"
B="$HOME/.gym-substrate-host/baseline"
[ -s "$B/home.txt" ] || { echo "no baseline under $B; run hack/host/baseline.sh --save at the start"; exit 1; }
export PATH="$HOME/.local/bin:$HOME/tools/go/bin:$HOME/go/bin:$PATH"
OURS_DIRS="$WORK $HOME/tools $HOME/go $HOME/.kube $HOME/.docker $HOME/.cache/uv $HOME/.cache/go-build $HOME/.cache/ate-setup $HOME/.local/share/uv $HOME/.config/uv $HOME/logs $EXTRA_DIRS"
OURS_FILES="$HOME/.local/bin/kubectl $HOME/.local/bin/uv $HOME/.local/bin/uvx $HOME/.local/bin/env $HOME/.local/bin/env.fish"
home_entries() { find "$HOME" -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -v -x '.gym-substrate-host' | sort; }
extras() { home_entries | grep -v -x '.ssh' | comm -23 - "$B/home.txt"; }
if [ "$MODE" = plan ]; then
  echo "baseline from $(cat "$B/when.txt"): $(tr '\n' ' ' < "$B/home.txt")"
  echo "would remove dirs: $OURS_DIRS"
  echo "would remove files: $OURS_FILES"
  echo "home entries not in the baseline (removed after printing): $(extras | tr '\n' ' ')"
  echo "/tmp entries of mine newer than the baseline: $(find /tmp -maxdepth 1 -user "$(id -un)" -newermt "$(cat "$B/when.txt")" 2>/dev/null | wc -l)"
  exit 0
fi
echo "$(date -u +%FT%TZ) wipe: $MODE start"
pkill -f "[l]adder-chain.sh|[l]adder.sh|[r]un_arm.sh|[b]urn_driver.py|[h]ost-sampler.sh|[r]eplay_policy.py" 2>/dev/null
pkill -f "[g]ym eval run" 2>/dev/null; pkill -f "[g]ym env start" 2>/dev/null
[ -x "$WORK/gym/.venv/bin/ray" ] && "$WORK/gym/.venv/bin/ray" stop --force >/dev/null 2>&1
pkill -f "[k]ubectl port-forward" 2>/dev/null
if [ -x "$WORK/substrate/hack/delete-kind-cluster.sh" ]; then (cd "$WORK/substrate" && hack/delete-kind-cluster.sh) >/dev/null 2>&1; fi
kind delete cluster >/dev/null 2>&1; docker rm -f kind-registry >/dev/null 2>&1; docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1
echo "kind clusters: [$(kind get clusters 2>/dev/null | tr '\n' ' ')] containers: $(docker ps -aq 2>/dev/null | wc -l) our processes: $(pgrep -u "$(id -un)" -fc 'gym|replay_policy|host-sampler|ladder|kubectl|ray' || true)"
if [ "$MODE" = wipe ]; then
  docker system prune -af --volumes >/dev/null 2>&1; echo "docker images left: $(docker images -q 2>/dev/null | wc -l)"
  chmod -R u+w "$HOME/go" "$HOME/.cache/go-build" 2>/dev/null   # the Go module cache is read-only and blocks rm
  for d in $OURS_DIRS; do rm -rf -- "$d"; done
  for f in $OURS_FILES; do rm -f -- "$f"; done
  rmdir "$HOME/.local/bin" "$HOME/.local/share" "$HOME/.local" "$HOME/.config" "$HOME/.cache" 2>/dev/null
  ex=$(extras | tr '\n' ' '); if [ -n "$ex" ]; then echo "removing home entries not in the baseline: $ex"; (cd ~ && for e in $ex; do rm -rf -- "./$e"; done); fi
  sed -i '/\.local\/bin\/env/d' ~/.bashrc ~/.profile 2>/dev/null
  find /tmp -maxdepth 1 -user "$(id -un)" -newermt "$(cat "$B/when.txt")" -exec rm -rf {} + 2>/dev/null
  echo "home now: $(home_entries | tr '\n' ' ')"
fi
echo "$(date -u +%FT%TZ) wipe: $MODE done (then sudo hack/host/revert-root.sh, the final check, rm -rf ~/.ssh last)"
