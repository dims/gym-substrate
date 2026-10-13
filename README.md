# gym-substrate

The pieces that connect [NeMo Gym](https://github.com/NVIDIA-NeMo/Gym) sandboxes to [Agent Substrate](https://github.com/agent-substrate/substrate) actors, kept outside both repositories.

- `cmd/sandbox-agent`: a small HTTP server that runs inside a Substrate actor and gives the Gym Substrate provider what Substrate itself does not offer: `exec`, `upload`, `download` and a readiness probe. It rides into any workload image on an image volume, so the image runs untouched. The contract is in [docs/contract.md](docs/contract.md).
- `hack/gym-templates.sh`: builds the agent image with `ko` and creates one Substrate `ActorTemplate` per workload image with the agent mounted and set as the container command.

- `gym_substrate/`: the Gym `SandboxProvider` named `substrate`, installed as a plugin through the `nemo_gym.sandbox_providers` entry point: create, exec, upload, download, status, pause, resume and close against Substrate actors, with the generated ateapi gRPC stubs under `_ateapi/`. Details in [docs/provider.md](docs/provider.md). The same code sits on the `substrate-provider-upstream` branch of [dims/Nemo-Gym](https://github.com/dims/Nemo-Gym/tree/substrate-provider-upstream) as the candidate for an in-tree Gym PR; this repository is where it is developed.

- `scripts/` and `manifests/`: a replay policy and a runner for a pause-against-never comparison without a model, an oversubscription probe, a scoped actor delete, a WorkerPool sized for the templates, NodePort Services and a Grafana dashboard (see below).

[docs/provider.md](docs/provider.md) says what the cluster needs and what to expect under load; [docs/architecture.md](docs/architecture.md) has the contracts between the two sides, the sequences and the failure handling.

## Install the provider

In a Gym checkout (Python 3.13.14 or later, as Gym requires):

```bash
uv add "gym-substrate @ git+https://github.com/dims/gym-substrate"
uv sync --extra dev --extra sandbox
```

`uv add` records the package in the checkout's `pyproject.toml` and `uv.lock`, so a later `uv sync` keeps it; `uv pip install git+https://github.com/dims/gym-substrate` into the venv works for a one-off, until the next sync.

Gym selects the provider through the agent's `sandbox_provider` key, which names a block like the `sandbox:` block of `gym_substrate/configs/substrate.yaml`; its one provider key, `substrate`, is resolved through the entry point. Copy that file and set the addresses (see `docs/provider.md`).

## Build and test

```bash
go test ./...
KO_DOCKER_REPO=<registry> ko build --base-import-paths ./cmd/sandbox-agent
uv sync && uv run pytest
```

`scripts/generate_ateapi_stubs.sh /path/to/substrate` regenerates the gRPC stubs from Substrate's `ateapi.proto` and records the commit. `scripts/smoke_provider.py` runs one sandbox through the provider against a live cluster (see [docs/provider.md](docs/provider.md)).

## Create templates

With a Substrate install and `kubectl-ate` on the path:

```bash
BUCKET_NAME=<snapshot bucket> KO_DOCKER_REPO=<registry> WORKLOAD=gym ACTOR_CPU=1 ACTOR_MEMORY=4Gi \
  hack/gym-templates.sh python:3.12-slim <image>...
```

Environment: `ATESPACE` (default `nemo-gym`), `WORKLOAD` (the WorkerPool label the templates select, default `sandbox`, Substrate's demo pool), `ACTOR_CPU` and `ACTOR_MEMORY` (per-actor limits, defaults 1 and 1Gi; SWE-bench needs 4Gi), `AGENT_IMAGE` (a digest-pinned agent image instead of a `ko` build). `docs/provider.md` explains the bucket, the pool and the golden snapshot to wait for.

## Scripts and manifests

- `scripts/smoke_provider.py`: one sandbox through the provider against a live cluster.
- `scripts/replay_policy.py`: an OpenAI-compatible server that replays recorded Gym rollouts after a think time, so a run needs no model.
- `scripts/run_arm.sh`: one arm of a pause-against-never comparison: the Gym servers restarted with a provider config, N rollouts at once, occupancy samples, a summary.
- `scripts/oversub_provider.py`: more sandboxes than workers, each stepping with gaps, straight against the provider.
- `scripts/delete_actors.py`: delete actors by name or by state.
- `hack/rerun-all.sh`: a prepared host to a passing gate in one pass, each step gated on its evidence line; `hack/host-check.sh`, `kind-up.sh`, `gvisor-asset.sh`, `images.sh`, `gym-checkout.sh` and `gate.sh` are its steps (docs/provider.md, From zero).
- `manifests/gym-workerpool.yaml`, `manifests/nodeports.yaml`, `manifests/grafana-sandbox-lifecycle.yaml`: a pool of eight-slot workers for cpu 1 / 4Gi actors, the API and the router on NodePorts, Grafana with the "Sandbox lifecycle" dashboard.

## Security

The agent runs any command a client sends and has no authentication of its own; it relies on the Substrate router in front of it. Do not expose a router that fronts these actors to untrusted clients.

## Origin and license

The agent started as the `demos/sandbox` server in Agent Substrate and keeps that code's Apache-2.0 license and copyright headers. Apache-2.0 for the repository; see [LICENSE](LICENSE).
