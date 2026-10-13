# Substrate sandbox provider

Runs sandboxes as [Substrate](https://github.com/agent-substrate/substrate)
actors. Substrate can pause or suspend an actor and bring it back on demand, so
an idle sandbox holds no worker; for a benchmark run that spends most of its
wall-clock waiting on a policy model, that is the reason to use this backend.

## How it works

```
provider ── gRPC ──────> ateapi          Create / Pause / Suspend / Delete actor
         └─ HTTP ──────> atenet router ─> sandbox server (inside the actor)
```

Control operations go to `ateapi`. Commands and file transfers go to a small
HTTP server inside the actor, addressed through the `atenet` router by the
`ate-target-actor: <atespace>/<actor>` header. The router resumes a paused or
suspended actor before routing to it, so nothing has to resume it explicitly.
When no worker has room the router parks the request for its budget and then
answers 503; the provider waits and sends the request again, because it never
reached the actor. A 503 for an actor mid-transition or a control-plane
conflict is retried for about a minute; one that names a crashed or deleted
actor, or that the provider cannot explain, fails the step at once.

The in-actor server is this repository's `cmd/sandbox-agent`. It is static, so an
`ActorTemplate` mounts its image as a read-only image volume into the benchmark
image, which runs untouched, and sets it as the container command.

## Requirements

**NeMo Gym.** Upstream `main` plus these pull requests until they merge:

- [NVIDIA-NeMo/Gym#4483](https://github.com/NVIDIA-NeMo/Gym/pull/4483): `openai_utils` drops litellm's `provider_specific_fields` from replayed chat history. Without it every `mini_swe_agent_2` rollout fails with a 422 on its second turn.
- [#4472](https://github.com/NVIDIA-NeMo/Gym/pull/4472): `mini_swe_agent_2` ends a rollout when its sandbox is gone or an exec does not run (return code 125 with an `error_type`). Without it the rollout steps on against a dead sandbox and scores 0 with no error.
- [#4471](https://github.com/NVIDIA-NeMo/Gym/pull/4471): the per-instance sandbox config is replaced atomically. Concurrent rollouts tore it.
- [#4551](https://github.com/NVIDIA-NeMo/Gym/pull/4551): a distribution that publishes a `nemo_gym.sandbox_providers` entry point is installed into every server venv through `head_server_deps`. Without it, install the plugin into the agent server's venv by hand (see Run).

**Substrate.** Any install of `main` at or past f03327bd runs the provider. Runs with more sandboxes than slots used these pull requests as well:

- [agent-substrate/substrate#2558](https://github.com/agent-substrate/substrate/pull/2558): a lifecycle workflow runs to its end when the caller goes away. Without it a `PauseActor` that outruns the client deadline leaves the actor `PAUSING` for good.
- [#2491](https://github.com/agent-substrate/substrate/pull/2491): a retried pause reuses the checkpoint image a cancelled attempt left instead of crashing the actor.
- [#2559](https://github.com/agent-substrate/substrate/pull/2559): terminate deletes the sandbox root first. Under load `runsc delete` of the application container died at its budget and left actors `DELETING` with their slots held.
- [#2492](https://github.com/agent-substrate/substrate/pull/2492): a slow first answer passes the wakeup probe. A restore wave onto a starved node crashed healthy actors otherwise.
- [#2493](https://github.com/agent-substrate/substrate/pull/2493), [#2496](https://github.com/agent-substrate/substrate/pull/2496), [#2557](https://github.com/agent-substrate/substrate/pull/2557): ateapi's PostgreSQL pool defaults to 20 connections, the postgres probes get 5 s and 10 s timeouts, and the control-plane pods get CPU requests and 5 s probes. Without them a few hundred sandboxes per node starve the control plane.
- [#2560](https://github.com/agent-substrate/substrate/pull/2560): the router's route timeout, parked budget and ext_proc breaker become install settings. Without it, patch the router Deployment after every install (see Cluster).

Last tested: the plugin at c02a7db against Substrate `main` f03327bd with those changes and Gym `main` 43a5e5c0b with those pull requests.

**Tools.** `kubectl`, `kubectl-ate` (built from the Substrate checkout), `ko`, `go`, `uv`, and `docker` to push images into the cluster's registry.

## Setup

### Cluster

Any Substrate install runs the provider; the settings below decide how many sandboxes
it carries. Substrate's `docs/request-parking.md` has the router's mechanics and defaults.

**Router.** Four flags on the `atenet-router` Deployment:

- `--route-timeout` (default 5 min) bounds one request end to end. Set it above the
  longest exec you allow (`exec.default_timeout_s` and `mini_swe_agent_2`'s
  `eval_timeout`, both 1800 s): `30m30s`. A command that outruns it gets a 504 while it
  keeps running in the sandbox.
- `--parked-request-budget` (default 5 s) is how long the router holds a request whose
  actor has no free slot before it answers 503; the provider then waits
  `exec.capacity_retry_delay_s` and sends the request again, at the back of the lot.
  With more sandboxes than slots, set it to how long a step may wait for a slot: `10m`.
  Two minutes was too short at twice the slots; every second-wave request cycled
  through 503 and retry. `probe.timeout_s` must stay above the budget (660 s here), or
  the client cuts a parked readiness probe and parks it again.
- `--parked-request-max` (default 1024) is the parking lot. A request beyond it gets 503
  `router at capacity` at once, which the provider retries after
  `capacity_retry_delay_s`. Size it to the sandboxes beyond the slots.
- `--extproc-max-requests` (default twice the lot) is Envoy's circuit breaker on the
  ext_proc cluster. Simultaneous requests above it get an Envoy 503 `overflow` with no
  actor reason in it, so the provider fails the step. Set it to the number of sandboxes
  that may step at once; `8192` carried 1536 synchronized steps.

[agent-substrate/substrate#2560](https://github.com/agent-substrate/substrate/pull/2560)
makes these install settings (`ATE_ATENET_ROUTE_TIMEOUT`,
`ATE_ATENET_PARKED_REQUEST_BUDGET`, `ATE_ATENET_EXTPROC_MAX_REQUESTS`) and sizes the
router's grace period with the budget. Until it merges, patch the Deployment after every
install, since a reinstall reverts it; a router rollout then cuts parked requests,
because the grace period is not raised:

```bash
kubectl -n ate-system patch deploy atenet-router --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--route-timeout=30m30s"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--parked-request-budget=10m"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--extproc-max-requests=8192"}]'
kubectl -n ate-system rollout status deploy/atenet-router
```

**Workers and templates.** A worker hosts several actors at once. Each actor subtracts
its template's cpu and memory limits from the worker's limits; requests are not counted.
A slot is one actor of the template's size, so a worker of cpu 8 / 32 GiB holds eight
actors of cpu 1 / 4 GiB. SWE-bench test suites peak at 2 to 4 GiB.
`manifests/gym-workerpool.yaml` is such a pool; set `workerImage` to the install's
`ateom-gvisor` image, which the demo pool shows after
`hack/install-ate-kind.sh --deploy-demo-sandbox`:
`kubectl get workerpool -n ate-demo-sandbox sandbox-workerpool -o jsonpath='{.spec.workerImage}'`.
Templates made with `WORKLOAD=gym` select the pool by its label. With several nodes,
create one pool per node with a `nodeSelector`: a paused actor's snapshot stays on its
node and its next resume must land there.

**Control plane under load.** Hundreds of sandboxes per node starve the control-plane
pods that share the nodes. Until
[#2557](https://github.com/agent-substrate/substrate/pull/2557),
[#2496](https://github.com/agent-substrate/substrate/pull/2496) and
[#2493](https://github.com/agent-substrate/substrate/pull/2493) merge: give
`ate-api-server`, `atenet-router`, `atenet-egress`, `ate-controller` and `atelet` CPU
requests and probes of 5 s with a failure threshold of 6; give postgres probe timeouts of
5 s (readiness) and 10 s (liveness), `max_connections=500` and a CPU request; start
ateapi with `--postgres-pool-max-conns=20` (the default is one connection per CPU per
replica) and four replicas. On kind, keep the stateless control-plane pods on the
control-plane node with a `nodeSelector` and a toleration, so no sandbox runs beside
them. Patch between runs, never while actors exist.

**Reaching the cluster.** `connection.ateapi_addr` and `connection.atenet_addr` take any
host:port that reaches the `api` Service (gRPC over TLS, 443) and the `atenet-router`
Service (HTTP, 80). A port-forward serves a smoke. For a run, apply
`manifests/nodeports.yaml` (30443 and 30080 on every node): `kubectl port-forward`
collapsed under load and cancelled in-flight pauses. On kind the node address is
`docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' kind-control-plane`.

**Host.** `fs.inotify.max_user_instances` (default 128, one budget per user shared by
kubelet, containerd and every sandbox; 65536 held at 3072 sandboxes) and
`fs.inotify.max_user_watches`; `net.ipv4.neigh.default.gc_thresh1`, `gc_thresh2` and
`gc_thresh3` (the default ceiling of 1024 is global across network namespaces and
overflows above about 1000 sandbox addresses;
[#2497](https://github.com/agent-substrate/substrate/pull/2497) warns when it is at the
default); `fs.aio-max-nr`; `nofile` 1048576 for the container runtime. Above a few
hundred sandboxes per node, reserve CPU for the kubelet
([#2495](https://github.com/agent-substrate/substrate/pull/2495) on kind), or the node
flaps NotReady and the taint manager evicts its workers.

**arm64 and 64 KiB pages.** gVisor does not emulate, so an image must match the node
architecture or the actor fails at `runsc start`; map image names with
`sandbox_spec.image_rewrites` (see Run). On a 64 KiB-page kernel the released gVisor
assets fail at `runsc start` too: build `runsc` from a gVisor master that has the
64 KiB restore guards removed (b27af97d3b, 2026-10-09) with `--define=pagesize=64k`,
upload the tarball to the install's object store, and point the `gvisor-default`
SandboxConfig's arm64 asset at it before creating any template; a template created
before the swap never gets a golden snapshot.

### Templates

The cluster needs one `ActorTemplate` per image. An `ActorTemplate` spec is
immutable and an actor names a template rather than an image, so the set is
built ahead of a run rather than on demand. `hack/gym-templates.sh` builds the
agent image and the templates; pass each image as NeMo Gym will ask for it, with
or without the `docker.io/` prefix, since both sides drop it before deriving the
name:

```bash
# against the cluster kubectl points at
KO_DOCKER_REPO=<registry> BUCKET_NAME=<snapshot bucket> WORKLOAD=<pool label> \
  ACTOR_CPU=1 ACTOR_MEMORY=4Gi hack/gym-templates.sh \
  swebench/sweb.eval.x86_64.django_1776_django-11099:latest
```

The provider derives a template's name from the image it is asked for, so the
two sides agree without a shared lookup table. That derivation is pinned by a
unit test for a real SWE-bench image; if it changes, the generator must change
with it.

### Run

In a Gym checkout, build the environment with `uv sync --extra dev --extra sandbox`,
then install this package into it with
`uv pip install --no-deps git+https://github.com/dims/gym-substrate`.
`--no-deps` matters: this package declares `nemo-gym` with a git source (for its own
tests), and a plain install resolves that source and puts a second `nemo_gym` from Gym
main into `site-packages`, which shadows the checkout's editable install for every
console script such as `gym`. Install it after the last sync: a plain `uv sync` removes
packages that are not in Gym's lock. A server that builds its own venv from a `requirements.txt` in its directory, as
`mini_swe_agent_2` does, resolves the provider inside that venv. With
[NVIDIA-NeMo/Gym#4551](https://github.com/NVIDIA-NeMo/Gym/pull/4551) every distribution
that publishes a `nemo_gym.sandbox_providers` entry point is installed there through
`head_server_deps`. Without it, add `gym-substrate @ git+https://github.com/dims/gym-substrate`
to that file, or install it there once the first `gym env start` has built the venv
(about a minute); Gym keeps the venv and only adds to it:

```bash
uv pip install --no-deps --python responses_api_agents/mini_swe_agent_2/.venv/bin/python \
  git+https://github.com/dims/gym-substrate
```

Start the servers from the activated venv. Running them through `uv run`
makes Ray's `uv run` hook demand a `pyproject.toml` inside the agent's directory and the
`mini_swe_agent_2` server exits at startup.

`connection.ateapi_addr` and `connection.atenet_addr` take any host:port that reaches
the `api` Service and the `atenet-router` Service: the port-forwards below for a smoke,
the NodePorts of `manifests/nodeports.yaml` for a run (see Cluster). When local ports
8080 and 8000 are taken, forward elsewhere and set both addresses.

```bash
kubectl port-forward -n ate-system svc/api 8080:443 &
kubectl port-forward -n ate-system svc/atenet-router 8000:80 &

source .venv/bin/activate
gym env start "+config_paths=[responses_api_agents/mini_swe_agent_2/configs/mini_swe_agent_2.yaml,/path/to/gym-substrate/gym_substrate/configs/substrate.yaml,<model>.yaml]"
```

gVisor does not emulate, so an image must match the node architecture or the
actor fails to start with `runsc start`: exit status 128. SWE-bench publishes
`sweb.eval.x86_64.*` images and, for part of the instances, `sweb.eval.arm64.*`;
on arm64 nodes map one to the other with the agent's `sandbox_spec.image_rewrites`
(`from: docker.io/swebench/sweb.eval.x86_64.`, `to: <registry>/swebench/sweb.eval.arm64.`).

### Live smoke

`scripts/smoke_provider.py` runs one sandbox through create, the parked state,
exec (a resume), a timeout, status, download and close, from the venv the plugin
is installed in:

```bash
ATEAPI_ADDR=localhost:8080 ATENET_ADDR=localhost:8000 \
  python scripts/smoke_provider.py python:3.12-slim pause_after_exec
```

The image argument is the exact string the template was generated from
(`localhost:5001/python:3.12-slim` for an image pushed to the kind registry), since
the template name is derived from it.

### A pause-against-never comparison

`scripts/replay_policy.py` answers chat completions from recorded Gym rollouts after a
think time (`--think-s` constant, or `--think-mean-s` exponential, seeded per rollout and
turn; the counters restart on `POST /reset`), so a run needs no model. Point the model
server at it with an `env.yaml` in the Gym checkout, then run one arm per provider config
with `scripts/run_arm.sh`; the control arm is a copy of the config with
`suspend_policy: never`:

```bash
printf 'policy_base_url: http://127.0.0.1:9797/v1\npolicy_api_key: replay\npolicy_model_name: replay\n' > env.yaml
python /path/to/gym-substrate/scripts/replay_policy.py \
  --rollouts responses_api_agents/mini_swe_agent_2/data/example_rollouts.jsonl --port 9797 --think-mean-s 15 &
/path/to/gym-substrate/scripts/run_arm.sh ab12-pause /path/to/substrate.yaml 12
/path/to/gym-substrate/scripts/run_arm.sh ab12-never /path/to/substrate-never.yaml 12
```

Each arm prints the eval's exit code, the actors left behind, the rewards and the mean
number of actors holding a worker. `manifests/grafana-sandbox-lifecycle.yaml` shows the
lifecycle live: transitions, resumes by snapshot kind, parked requests, restore phases,
workers by state (`kubectl -n otel-system port-forward svc/grafana 3000:3000`, then
`/d/sandbox-lifecycle`; anonymous admin, so keep it on a port-forward).
`scripts/oversub_provider.py` runs the same idea without Gym: N sandboxes stepping with
gaps, straight against the provider.

## Authentication and trust

`ateapi` rejects unauthenticated calls. The provider mints a ServiceAccount
token through the Kubernetes `TokenRequest` API, the same way `kubectl-ate`
authenticates, using the local kubeconfig or in-cluster credentials. The
serving CA is read from the cluster's `ClusterTrustBundle`.

Credentials are resolved inside the provider rather than through `${oc.env:...}`
interpolation in the config block: the per-instance config is written to disk,
so a token placed there would be written in plaintext, and it would not reach a
remote worker anyway.

The data path is different. The router's ingress port is unauthenticated today
and the in-actor server runs whatever it is sent, as root. Anyone who can reach
the router Service and knows `<atespace>/<actor>` can run commands in that
sandbox. Keep the router unexposed (a port-forward, or a NetworkPolicy that
admits only the Gym servers) until Substrate's ingress authentication lands.

## Configuration

```yaml
sandbox:
  substrate:
    connection:
      ateapi_addr: localhost:8080
      atenet_addr: localhost:8000
      atespace: nemo-gym            # actors are created here
      template_namespace: nemo-gym  # templates are looked up here
    create:
      ready_timeout_s: 1200         # create() and resume() wait this long for the actor to answer
      ready_queue_timeout_s: 3600   # and this long more while the router queues the probe for a worker slot
      suspend_policy: pause_after_exec   # never | after_exec | pause_after_exec
      idle_before_suspend_s: 1.0
    exec:
      default_timeout_s: 1800
      concurrency: 32             # per provider instance; Gym makes one per sandbox
      capacity_retry_delay_s: 5
    probe:
      timeout_s: 660              # above the router's --parked-request-budget (10 min, see Cluster)
```

### `suspend_policy`

`pause_after_exec` calls `PauseActor` once the actor has been idle for
`idle_before_suspend_s` after a step, and after `create()` has made it ready:
the actor's worker is freed and its snapshot stays on the node, so the next
step resumes without a download but has to land on the same node. A new
sandbox therefore holds no worker through the policy's first think time; its
first command resumes it like any later one. The delay keeps back-to-back steps, such as an eval's
test runs, from each paying a checkpoint and a restore; an exec that arrives
during the delay cancels the pause, and an actor is never paused while a request
to it is in flight. An exec that arrives while a pause is already under way
waits for it to finish, because the router cannot resume an actor that is still
pausing.

`after_exec` calls `SuspendActor` instead: the snapshot is pushed to object
storage and any node can resume it. This pays a checkpoint upload per idle
period and a restore download at the start of the next step.

`never` leaves the actor running and is the control to measure against.

Whatever the policy, an actor whose worker is being evicted is suspended to
storage once idle, since a node-local pause would go away with the node: the
in-actor server reports the worker's `SIGTERM` on its next `/exec` reply, once,
and the provider suspends at the next idle moment (or in `pause()`). A paused
actor has no process to signal, so it gets no notice; its snapshot stays under
its node's `/var/lib/ate`, and Substrate does not move it when that node goes.
Until it does, suspend every Gym actor (`kubectl ate suspend`) before rolling a
worker pool or draining a node.

### Pause, resume and status

The provider implements `SupportsSandboxPauseResume`. `pause()` waits for
requests in flight to finish (a pause would checkpoint a running command and
cut its reply), calls `PauseActor` (or `SuspendActor` when the worker is being
evicted) and returns once the control plane reports the actor parked; it raises
if requests are still in flight after `connection.grpc_timeout_s`. `resume()`
sends a readiness probe through the router, which resumes the actor and parks
the probe until a worker has room. `status()` reports a paused, pausing,
suspended or suspending actor as `PAUSED`, a resuming or reverting one as
`STARTING`, a crashed one as `ERROR`, and a deleted one as `STOPPED`.

## Behavior under load

A slot is room on a worker for one actor of the template's size; a `RUNNING` actor holds
one and a `PAUSED` or `SUSPENDED` actor holds none. With N sandboxes on S slots, at most S
run at once; the rest are parked, `PAUSED` on their node under `pause_after_exec` or
waiting for their first slot under `never`. An exec against a parked actor is a resume
that needs a free slot, and the router parks the request for its budget. What to expect,
from runs at one to four times the slots:

- **Restore throughput bounds the pause path**, not CPU or memory. A pause step holds a
  slot for the checkpoint, the restore and the command; under load each of the first two
  takes tens of seconds, against well under a second on an idle node. Measure the hold
  time H of one step on your cluster (the dashboard's checkpoint and restore panels);
  with a think time T between steps, N actors on S slots drain only when
  T >= H x (N/S - 1). On a 352-thread host H was about 70 s and the host restored about
  four actors per second. Below the rule, parked waits run past the budget, the provider
  retries until the request budget (`default_timeout_s` plus 30 s), and the step fails
  with return code 125 and an `error_type`; with Gym#4472 the rollout then ends with an
  error instead of scoring 0 silently.
- **Pause pays when the think time is long against one checkpoint and restore.** The
  saving is the think time between commands; the cost is one cycle per idle period. At a
  think time of a few seconds the pause arm is slower per task than `never`, and at
  N = S `never` wins outright. Pause exists for N > S.
- **Create waits too.** A new actor's first readiness probe is a resume that may park for
  the whole budget per attempt. Time queued for a slot is charged to
  `create.ready_queue_timeout_s`, not `ready_timeout_s`; an empty 504 from the router (its
  fail-fast when a resume flight outruns its deadline) counts as queued. A failed create
  is deleted in the background for up to 15 min, because the parked probe's resume flight
  still holds the actor's lease.
- **Synchronized bursts hit the ext_proc breaker.** Sandboxes stepping in lockstep get an
  Envoy 503 `overflow` above `--extproc-max-requests`, which carries no actor reason, so
  the provider fails the step. Desynchronize the steps or raise the breaker.
- **Control calls fail transiently under bursts.** ateapi answers `ABORTED` (lease held,
  version conflict), `UNAVAILABLE` (restart) and `INTERNAL` (PostgreSQL out of
  connections); the provider retries five times with backoff, about eight seconds in all.
- **A paused actor is pinned to its node.** Its snapshot lives under that node's
  `/var/lib/ate`; a drain or a pool rollout loses it. Suspend every actor first.
- **A dead sandbox is a `RUNNING` actor.** Substrate does not notice the application
  exit; the next exec fails and the provider reports return code 125, and Gym#4472 ends
  the rollout.
- **The agent server caps rollouts in flight.** `mini_swe_agent_2`'s `concurrency` is 64;
  raise it in an override config for larger runs.
- **Nothing times actors out.** A dead agent process leaves its actors behind, paused and
  nearly free, until something deletes them: `scripts/delete_actors.py` by state or by
  name.

## What this provider does not honor

Declined rather than faked:

| Spec field | Why |
| --- | --- |
| `resources` | Actors are sized by their `ActorTemplate`, not per sandbox. |
| `ttl_s` | Substrate has no TTL; a paused actor already costs almost nothing. |
| `entrypoint` | The container command runs the sandbox server. |

`user` must be `root` (or unset). Every container in an actor shares one fixed
identity, so there is no user to switch to; anything else is refused rather than
silently ignored.

Commands run under `bash` when the image has it, else `sh`: `mini_swe_agent_2`
sources conda's `conda.sh`, which is not portable to dash. `spec.env` is applied
to each command, not to the container, so background processes a command leaves
behind do not see it. Uploads and downloads move one whole file per request
through memory; they are meant for seed files and results, not repositories.

## Regenerating the gRPC stubs

`gym_substrate/_ateapi/` holds stubs generated from Substrate's `ateapi.proto`;
the Substrate commit they came from is recorded in its `__init__.py`:

```bash
scripts/generate_ateapi_stubs.sh /path/to/substrate
```
