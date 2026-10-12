# gym-substrate

The pieces that connect [NeMo Gym](https://github.com/NVIDIA-NeMo/Gym) sandboxes to [Agent Substrate](https://github.com/agent-substrate/substrate) actors, kept outside both repositories.

- `cmd/sandbox-agent`: a small HTTP server that runs inside a Substrate actor and gives the Gym Substrate provider what Substrate itself does not offer: `exec`, `upload`, `download` and a readiness probe. It rides into any workload image on an image volume, so the image runs untouched. The contract is in [docs/contract.md](docs/contract.md).
- `hack/gym-templates.sh`: builds the agent image with `ko` and creates one Substrate `ActorTemplate` per workload image with the agent mounted and set as the container command.

- `gym_substrate/`: the Gym `SandboxProvider` named `substrate`, installed as a plugin through the `nemo_gym.sandbox_providers` entry point: create, exec, upload, download, status, pause, resume and close against Substrate actors, with the generated ateapi gRPC stubs under `_ateapi/`. Details in [docs/provider.md](docs/provider.md). The same code sits on the `substrate-provider-upstream` branch of [dims/Nemo-Gym](https://github.com/dims/Nemo-Gym/tree/substrate-provider-upstream) as the candidate for an in-tree Gym PR; this repository is where it is developed.

## Install the provider

```bash
uv pip install git+https://github.com/dims/gym-substrate
```

Gym then resolves `provider: {substrate: {...}}` in a sandbox config through the entry point; `gym_substrate/configs/substrate.yaml` is a starting config.

## Build and test

```bash
go test ./...
KO_DOCKER_REPO=<registry> ko build --base-import-paths ./cmd/sandbox-agent
uv sync && uv run pytest
```

`scripts/generate_ateapi_stubs.sh /path/to/substrate` regenerates the gRPC stubs from Substrate's `ateapi.proto` and records the commit.

## Create templates

With a Substrate install and `kubectl-ate` on the path:

```bash
BUCKET_NAME=<snapshot bucket> KO_DOCKER_REPO=<registry> hack/gym-templates.sh python:3.12-slim <image>...
```

Environment: `ATESPACE` (default `nemo-gym`), `WORKLOAD` (the WorkerPool label the templates select, default `sandbox`), `ACTOR_CPU` and `ACTOR_MEMORY` (per-actor limits, default cpu 1), `AGENT_IMAGE` (a digest-pinned agent image instead of a `ko` build).

## Security

The agent runs any command a client sends and has no authentication of its own; it relies on the Substrate router in front of it. Do not expose a router that fronts these actors to untrusted clients.

## Origin and license

The agent started as the `demos/sandbox` server in Agent Substrate and keeps that code's Apache-2.0 license and copyright headers. Apache-2.0 for the repository; see [LICENSE](LICENSE).
