# Sandbox agent HTTP contract

The agent listens on `PORT` (default `80`) inside the actor. Clients reach it through the Substrate router with the `ate-target-actor: <atespace>/<actor>` header; the router resumes a suspended or paused actor before forwarding. Commands run through the shell named by `SANDBOX_SHELL`, else `bash` when the image has it, else `sh`, as the one identity the actor runs as.

## `GET /readyz`

`200` with a text body once the agent serves. Templates use it as the wakeup probe after a restore.

## `POST /exec`

Request:

```json
{"command": "ls -la", "cwd": "/repo", "env": {"K": "v"}, "timeout_s": 30, "user": ""}
```

`command` is one shell string and is required. `user` must be empty, `root` or `0`; anything else is `400`, the actor has one identity.

Response:

```json
{"stdout": "...", "stderr": "...", "exit_code": 0, "error_type": "", "evicting": false}
```

- `stdout` and `stderr` are each capped at 8 MiB.
- The command runs in its own process group; on `timeout_s` the group is killed and `exit_code` is `125`, the sentinel the Gym sandbox SDK uses for "no process exit status". `error_type` is then `timeout`, or `sandbox` when the command could not be started at all.
- `evicting` is `true` on the first reply after the worker sent the actor `SIGTERM` (its pod is going away). The agent keeps serving so the actor can still be suspended within the grace period; the client is expected to pause or suspend the actor on seeing it.

## `POST /upload?path=<file>`

Body is the file content. Creates parent directories. `204` on success.

## `GET /download?path=<file>`

The file as `application/octet-stream` with `Content-Length`. `404` when missing, `400` for a directory.

## `POST /process`

The original Substrate demo endpoint, kept for its client: `{"command": ["ls", "-la"], "envvars": {}, "cwd": "", "timeout": "30s"}` returns `{"stdout", "stderr", "exitCode", "error"}`.
