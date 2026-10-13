# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""OpenAI-compatible chat-completions server that replays recorded NeMo Gym rollouts.

    python scripts/replay_policy.py --rollouts example_rollouts.jsonl --think-mean-s 15 --seed 1

Run it from the Gym venv, which has fastapi and uvicorn.

Each request is answered with the recorded assistant turn whose index equals the
number of assistant messages already in the conversation, after a pause that
stands in for model latency: a constant --think-s, or with --think-mean-s an
exponential draw with that mean (recorded SWE-bench traces put a step at about
15 s of model time). Draws are seeded per (rollout, turn) and
handed out in request order, so two runs of the same workload see the same
multiset of think times per turn and an A/B between them is fair, provided
POST /reset is called before each measured run (the per-turn counters start
over; which rollout gets which draw still depends on arrival order). The rollout is picked by
matching the request's first user message against the recorded one; with a
single rollout loaded no matching is needed. Past the end of a recording it
answers with the submit command so the harness terminates.
"""

import argparse
import asyncio
import json
import logging
import os
import random
import re
import time
import uuid

import uvicorn
from fastapi import FastAPI, Request


LOG = logging.getLogger("replay")
SUBMIT = "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"
PR_DESCRIPTION = re.compile(r"<pr_description>(.*?)</pr_description>", re.S)


def conversation_key(text: str) -> str:
    """The task statement, independent of the prompt template around it."""
    match = PR_DESCRIPTION.search(text)
    return " ".join((match.group(1) if match else text[:400]).split())


def load_rollouts(path: str) -> list[dict]:
    rollouts = []
    for line in open(path):
        if not line.strip():
            continue
        rollout = json.loads(line)
        turns: list[dict] = []
        current = None
        for item in rollout["response"]["output"]:
            kind = item.get("type")
            if kind == "message" and item.get("role") == "assistant":
                text = "".join(c.get("text", "") for c in item.get("content", []) if isinstance(c, dict))
                current = {"content": text, "calls": []}
                turns.append(current)
            elif kind == "function_call":
                if current is None:
                    current = {"content": "", "calls": []}
                    turns.append(current)
                current["calls"].append({"name": item["name"], "arguments": item["arguments"]})
            elif kind == "function_call_output":
                current = None
        users = [m for m in rollout["responses_create_params"]["input"] if m.get("role") == "user"]
        first_user = users[0]["content"] if users else ""
        if not isinstance(first_user, str):
            first_user = json.dumps(first_user)
        rollouts.append(
            {"instance_id": rollout.get("instance_id", "?"), "turns": turns, "key": conversation_key(first_user)}
        )
    return rollouts


def pick_rollout(rollouts: list[dict], messages: list[dict]) -> dict:
    if len(rollouts) == 1:
        return rollouts[0]
    first_user = next((m.get("content") for m in messages if m.get("role") == "user"), "")
    if not isinstance(first_user, str):
        first_user = json.dumps(first_user)
    key = conversation_key(first_user)
    for rollout in rollouts:
        if rollout["key"] == key:
            return rollout
    best = max(rollouts, key=lambda r: len(os.path.commonprefix([r["key"], key])))
    if len(os.path.commonprefix([best["key"], key])) >= 120:
        return best
    raise ValueError("no recorded rollout matches the conversation")


def build_app(rollouts: list[dict], think_s: float, think_mean_s: float | None, model: str, seed: int) -> FastAPI:
    app = FastAPI()
    served: dict[tuple[str, int], int] = {}

    def think_time(instance_id: str, turn_index: int) -> float:
        if not think_mean_s:
            return think_s
        # The k-th request for this turn, in either arm, gets the k-th draw.
        k = served.get((instance_id, turn_index), 0)
        served[(instance_id, turn_index)] = k + 1
        rng = random.Random(f"{seed}:{instance_id}:{turn_index}:{k}")
        return rng.expovariate(1.0 / think_mean_s)

    @app.get("/healthz")
    async def healthz():
        return {"ok": True, "rollouts": [r["instance_id"] for r in rollouts]}

    @app.post("/reset")
    async def reset():
        """Start the think-time draws over, so the next run is paired with the last."""
        served.clear()
        return {"ok": True}

    @app.get("/v1/models")
    async def models():
        return {"object": "list", "data": [{"id": model, "object": "model", "created": 0, "owned_by": "replay"}]}

    @app.post("/v1/chat/completions")
    @app.post("/chat/completions")
    async def chat_completions(request: Request):
        body = await request.json()
        messages = body.get("messages", [])
        rollout = pick_rollout(rollouts, messages)
        turn_index = sum(1 for m in messages if m.get("role") == "assistant")
        if turn_index < len(rollout["turns"]):
            turn = rollout["turns"][turn_index]
        else:
            turn = {
                "content": "replay exhausted; submitting",
                "calls": [{"name": "bash", "arguments": json.dumps({"command": SUBMIT})}],
            }
        LOG.info(
            "%s turn %d/%d calls=%d", rollout["instance_id"], turn_index, len(rollout["turns"]), len(turn["calls"])
        )
        await asyncio.sleep(think_time(rollout["instance_id"], turn_index))
        tool_calls = [
            {"id": f"call_{uuid.uuid4().hex[:16]}", "type": "function", "function": call} for call in turn["calls"]
        ]
        message = {"role": "assistant", "content": turn["content"] or None}
        if tool_calls:
            message["tool_calls"] = tool_calls
        return {
            "id": f"chatcmpl-{uuid.uuid4().hex[:16]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": body.get("model", model),
            "choices": [{"index": 0, "message": message, "finish_reason": "tool_calls" if tool_calls else "stop"}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }

    return app


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rollouts", required=True)
    parser.add_argument("--port", type=int, default=9797)
    parser.add_argument("--think-s", type=float, default=3.0, help="constant seconds to wait before each answer")
    parser.add_argument(
        "--think-mean-s", type=float, default=None, help="draw the wait from an exponential with this mean"
    )
    parser.add_argument("--model", default="replay")
    parser.add_argument("--seed", type=int, default=1, help="seed for the per-(rollout, turn) think-time draws")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s: %(message)s")
    rollouts = load_rollouts(args.rollouts)
    LOG.info("loaded %d rollouts: %s", len(rollouts), [(r["instance_id"], len(r["turns"])) for r in rollouts])
    uvicorn.run(
        build_app(rollouts, args.think_s, args.think_mean_s, args.model, args.seed),
        host="127.0.0.1",
        port=args.port,
        log_level="warning",
    )


if __name__ == "__main__":
    main()
