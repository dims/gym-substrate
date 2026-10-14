# Demo: Gym sandboxes that hold no worker while the model thinks

For someone who runs NeMo Gym already. You know `gym env start`, `gym eval run` and the
sandbox providers; this repository adds one more provider, `substrate`, and a cluster that
makes it worth having. The idea in one line: Agent Substrate runs each sandbox as an
*actor* that can be checkpointed and restored in well under a second, the provider pauses
the actor one second after every command, and Substrate's router resumes it on the next
command. A sandbox waiting for the policy model holds no CPU and no memory, so a pool
carries more sandboxes than it has slots.

Everything below ran on one 32-vCPU host, amd64 and arm64 alike, with the recorded
rollouts standing in for the model. Nothing needs a GPU or an API key.

## 0. What you need

- A Linux host of about 32 vCPUs and 64 GiB with docker (with buildx), kind, kubectl,
  go, ko, uv and zstd. `hack/host-check.sh` tells you what is missing and changes
  nothing. On a 64 KiB-page kernel you also need a gVisor build for it (see
  `docs/provider.md`, Cluster).
- 45 minutes: 20 for the bring-up, the rest for the rollouts.

## 1. Bring everything up with one command

```bash
git clone https://github.com/dims/gym-substrate && cd gym-substrate
hack/host-check.sh
hack/rerun-all.sh --wipe
```

The pass prints a line per step and stops at the first one whose evidence is missing.
What goes by, with the lines to look for:

```
== 19:20:10Z kind-up
substrate at c427a6ae ...                     Substrate upstream main on a one-node kind cluster
ate-system pods: 9 running, 1 completed
page size 4096: stock gVisor asset            (64 KiB hosts: gvisor-default v3 arm64 sha 359a77f1 s3://...)
router args: ... --route-timeout=30m30s --parked-request-budget=10m --extproc-max-requests=8192
node ip 172.18.0.2; api np https 415, router np http 404
gym workers active: 3 of 3 (cpu 6 / 12Gi each)
== 19:23:16Z images
pushed localhost:5001/swebench/sweb.eval.x86_64.scikit-learn_1776_scikit-learn-14141:latest
pushed localhost:5001/python:3.12-slim
== 19:23:19Z templates
agent image localhost:5001/sandbox-agent@sha256:33a4... (linux amd64)
all templates have a golden (1)
== 19:24:11Z gym-checkout
gym head: 752e55c28, 10 commits over the base        Gym main plus the four pull requests
provider resolves: gym_substrate.provider ...        the plugin, installed with uv add
== 19:24:43Z gate
RESULT PASS                                           the live smoke (step 3)
gate-... policy=suspend_policy: pause_after_exec n=1 wall=303s eval_exit=0 leaked_actors=0
    "mean/reward": 1.0,
GATE PASS gate-...
== 19:36:20Z RERUN_DONE
```

Everything it made is under `~/gym-substrate-run` (`WORK`): the Substrate and Gym
checkouts, the provider configs, the logs. The Gym servers and the replay policy are left
running for the steps below.

## 2. Look at what is there

Substrate's objects are not Kubernetes objects; `kubectl-ate` (built into `WORK/bin`)
reads them through the API.

```
$ kubectl ate get actor-template -a nemo-gym
ATESPACE   NAME                   SANDBOX CLASS          GOLDEN TAG                             ERROR   AGE
nemo-gym   swb-26582a03b2f2743e   SANDBOX_CLASS_GVISOR   2cf7cc12-208f-4dd5-a2ad-81ffa5b461c4           37m
nemo-gym   swb-8ec64845df393cc3   SANDBOX_CLASS_GVISOR   86d1e632-ccdb-4240-bc7b-40dd14f04414           37m
```

One template per image, named from the image string (the provider derives the same name,
so the two sides need no lookup table). The GOLDEN TAG is a snapshot of the image booted
once with this repository's in-actor agent as the container command; every sandbox starts
by restoring it, which is why a create takes two seconds.

```
$ kubectl ate get workers
NAME       POOL             STATE                 ACTORS   CPU   MEMORY   POD
61a55426   gym-workerpool   WORKER_STATE_ACTIVE   0/1000   0/6   0/12Gi   ate-demo-sandbox/gym-workerpool-...
1eb29f63   gym-workerpool   WORKER_STATE_ACTIVE   0/1000   0/6   0/12Gi   ate-demo-sandbox/gym-workerpool-...
66366aa9   gym-workerpool   WORKER_STATE_ACTIVE   0/1000   0/6   0/12Gi   ate-demo-sandbox/gym-workerpool-...
```

Three workers of cpu 6 / 12Gi. The templates give each actor cpu 1 / 4Gi, so a worker
holds three and the pool has nine slots. Keep that number in mind for step 5.

On the Gym side nothing is new except one config file. `WORK/run/substrate.yaml` is the
provider block, pointed at the cluster:

```yaml
sandbox:
  substrate:
    connection:
      ateapi_addr: 172.18.0.2:30443      # Substrate's API, a NodePort on the kind node
      atenet_addr: 172.18.0.2:30080      # Substrate's router, the data path
    create:
      suspend_policy: pause_after_exec   # the policy this demo is about
      idle_before_suspend_s: 1.0
```

`mini_swe_agent_2` selects it through its `sandbox_provider: sandbox` key, exactly as it
selects any other provider. `WORK/run/image-rewrites.yaml` maps the image names the agent
asks for onto the kind registry, and `WORK/gym/env.yaml` points the model server at the
replay policy.

## 3. Watch one sandbox park and resume

The recorded output below predates Substrate merging `PAUSED` into `SUSPENDED`.
Current runs report `SUSPENDED` for both policies; the smoke checks that a pause
has a local-only snapshot and a suspend has a completed durable snapshot.

The smoke drives the provider directly, without Gym:

```bash
cd ~/gym-substrate-run/gym && source .venv/bin/activate
ATEAPI_ADDR=172.18.0.2:30443 ATENET_ADDR=172.18.0.2:30080 \
  python /path/to/gym-substrate/scripts/smoke_provider.py localhost:5001/python:3.12-slim pause_after_exec
```

```
create       2.2s  id=gym-ee329b7f6424  state=ACTOR_STATE_RUNNING
parked       1.5s  state=ACTOR_STATE_PAUSED  (first exec is a resume)
exec0        0.2s  rc=0 err=None state=ACTOR_STATE_RUNNING stdout='hello\nPython 3.12.15\nseed\nbar' stderr=''
parked       1.5s  state=ACTOR_STATE_PAUSED  (next exec is the resume)
exec1        1.3s  rc=0 err=None state=ACTOR_STATE_RUNNING stdout='step2' stderr=''
exec2        0.0s  rc=0 err=None state=ACTOR_STATE_RUNNING stdout='12\n11' stderr=''
timeout            rc=125 err=timeout
status             SandboxStatus.RUNNING
download           /work/pid='12'
close        0.1s  status=SandboxStatus.STOPPED
RESULT PASS
```

Read it top to bottom. `create` restores the golden snapshot in 2.2 s. One second of
idleness later the actor is `PAUSED`: its worker slot is free and its memory is a
checkpoint on the node. `exec0` arrives at a paused actor and still takes 0.2 s: the
router resumed it before forwarding the command. The provider never resumes anything
itself. `exec2` reads the pid written by `exec1`: the process state survived the pause. A
command that outruns its timeout comes back as return code 125 with `error_type:
timeout`, the convention Gym's sandbox SDK uses. `close` deletes the actor in any state.

## 4. One Gym rollout, as you know it

The servers are already running from step 1. In one terminal, watch the actors:

```bash
watch -n1 kubectl ate get actors -a nemo-gym
```

In another, run one rollout of the recorded task (the replay policy answers each policy
call with the recorded assistant message, after a think time):

```bash
cd ~/gym-substrate-run/gym && source .venv/bin/activate
gym eval run --no-serve --agent mini_swe_agent_2 \
  --input ~/gym-substrate-run/run/scikit-learn__scikit-learn-14141.jsonl --output out.jsonl --limit 1 --num-repeats 1
```

The actor flips between `RUNNING` with a worker pod while a command runs and `PAUSED`
with an empty WORKER POD column between commands; a turn's two to four commands arrive
back to back and share one pause. The rollout ends with reward 1.0 in about five minutes,
of which the pytest evaluation at the end is one long command of three to four minutes.
That evaluation is the part pausing cannot touch: the saving is the think time between the
agent's turns.

## 5. More sandboxes than slots: twelve on nine, pause against never

Now the point of the exercise. Twelve rollouts at once on nine slots, once with the pause
policy and once with `suspend_policy: never` (the config `WORK/run/substrate-never.yaml`),
the replay policy drawing a 15 s mean think time per policy call from the same seed in both
arms. `scripts/run_arm.sh` restarts the Gym servers with the given config, runs a warm-up
rollout, resets the replay's draws, runs the twelve, and samples the actor table every five
seconds for the occupancy.

```bash
cd ~/gym-substrate-run/gym && source .venv/bin/activate
pkill -f replay_policy.py
python /path/to/gym-substrate/scripts/replay_policy.py \
  --rollouts responses_api_agents/mini_swe_agent_2/data/example_rollouts.jsonl --think-mean-s 15 --seed 1 &
export GYM_DIR=$PWD RUN_DIR=~/gym-substrate-run/run LOG_DIR=~/gym-substrate-run/logs
export INPUT=$RUN_DIR/scikit-learn__scikit-learn-14141.jsonl EXTRA_CONFIGS=$RUN_DIR/image-rewrites.yaml
/path/to/gym-substrate/scripts/run_arm.sh demo12-pause $RUN_DIR/substrate.yaml 12
/path/to/gym-substrate/scripts/run_arm.sh demo12-never $RUN_DIR/substrate-never.yaml 12
```

`run_arm.sh` samples the actor states every five seconds. One sample per minute from each
arm, on the same host, the same twelve rollouts:

```
pause_after_exec                            never
20:08:55  11 PAUSED 1 RESUMING              20:26:33  9 RUNNING 3 SUSPENDED
20:09:15   8 PAUSED 4 RUNNING               20:27:34  9 RUNNING 3 SUSPENDED
20:09:56   3 PAUSED 9 RUNNING               20:28:36  9 RUNNING 3 SUSPENDED
20:11:59   3 PAUSED 9 RUNNING               20:29:37  9 RUNNING 3 SUSPENDED
20:14:01   2 PAUSED 6 RUNNING               20:31:39  1 DELETING 6 RUNNING 2 SUSPENDED
20:16:03   3 RUNNING                        20:33:42  3 RUNNING
```

With the pause policy all twelve sandboxes are created at once and parked through their
first think time (eleven `PAUSED`, one already resuming for its first command). Then they
take turns: at any moment up to nine run a command and the rest sit paused, holding
nothing. Once the evaluations start, one long command each, the nine slots fill and three
wait paused until a slot frees. With `never`, nine sandboxes take the nine slots for their
whole rollout and the other three are `SUSPENDED`: created, never yet resumed, their first
probe parked at the router until a whole rollout finishes.

The two summaries, the same rewards and 19 % fewer worker-seconds:

| arm | rollouts | wall | per task, median / p90 | mean workers held | worker-seconds |
|---|---|---|---|---|---|
| 12 on 9 slots, `pause_after_exec` | 12/12, reward 1.0 | 689 s | 6.3 / 11.2 min | 5.3 of 9 | about 3615 |
| 12 on 9 slots, `never` | 12/12, reward 1.0 | 812 s | 6.6 / 12.8 min | 5.6 of 9 | about 4475 |

```
demo12-pause policy=suspend_policy: pause_after_exec n=12 wall=689s eval_exit=0 leaked_actors=0
rollouts=12 reward_mean=1.00 errored=0
samples=136 mean_held=5.3 max_held=9 worker_seconds~3615
demo12-never policy=suspend_policy: never n=12 wall=812s eval_exit=0 leaked_actors=0
rollouts=12 reward_mean=1.00 errored=0
samples=160 mean_held=5.6 max_held=9 worker_seconds~4475
```

The saving is the think time between turns, 15 s per policy call here; the evaluation at
the end of each rollout is one command of three to four minutes that no policy can
shorten. A longer think time widens the gap, and below the slot count `never` wins, since
a pause and a resume cost a checkpoint and a restore each (`docs/provider.md`, Behavior
under load).

## 6. See it on the dashboard

```bash
kubectl apply -f /path/to/gym-substrate/manifests/grafana-sandbox-lifecycle.yaml
kubectl -n otel-system port-forward svc/grafana 3000:3000
```

`http://localhost:3000/d/sandbox-lifecycle` (anonymous admin, so keep it on the
port-forward): actor transitions per second by state, resumes by snapshot kind (golden
against node-local), router latency with and without a resume, requests parked waiting for
a worker, restore phases, workers by state, snapshot sizes. Run step 5 again with it open.

## 7. Where to go from here

- **Your own tasks.** Build a template per image the agent will ask for:
  `hack/images.sh <instance_id>...` puts the images in the registry and
  `hack/gym-templates.sh` makes the templates (`docs/provider.md`, Templates). The
  gate row is any line of a Gym input file.
- **Denser.** `POOL_REPLICAS`, `POOL_CPU` and `POOL_MEMORY` size the pool; 48 rollouts on
  24 slots is where the queue of parked requests becomes visible, and `docs/provider.md`,
  Behavior under load, says what to expect when restores become the limit.
- **Suspend instead of pause.** `suspend_policy: after_exec` sends the checkpoint to
  object storage, so any node can resume it, at the price of an upload per idle period.
- **Without Gym.** `scripts/oversub_provider.py` runs N sandboxes stepping with gaps
  straight against the provider.
- **From a training loop.** The provider implements `SupportsSandboxPauseResume`, so a
  loop can park a sandbox between turns without waiting for the idle timer.
- **How it fits together.** `docs/architecture.md` has the contracts, the sequences and
  the failure handling; `docs/contract.md` the in-actor agent's HTTP contract.

## Cleanup

```bash
hack/rerun-all.sh --wipe-only
```

stops the Gym servers and the replay policy, deletes the kind cluster and its registry,
and removes `WORK/gym` and `WORK/run`. Nothing else on the host is touched.
