# llama.cpp Server Setup

Kotoba can start a local llama.cpp-compatible `llama-server` process for the
current command. It does not bundle or install llama.cpp; `llama-server` must be
available on `PATH`, or `llama_server_path` must point to an executable.

Manual server mode still works:

```bash
llama-server -m /path/to/model.gguf --host 127.0.0.1 --port 8080
```

Initialize Kotoba with the same endpoint and model path:

```bash
kotoba init --server-url http://127.0.0.1:8080 --model-id custom --model-path /path/to/model.gguf --yes --skip-download
```

If `server_url` is a loopback root endpoint such as `http://127.0.0.1:8080` and
no server is already reachable, Kotoba starts:

```bash
llama-server -m /path/to/model.gguf --host 127.0.0.1 --port 8080
```

The managed process is kept alive only for that `kotoba` command and is stopped
when the command exits.

Autostart uses these config keys:

```toml
runtime = "llama_server"
server_autostart = true
llama_server_path = "llama-server"
server_startup_timeout_sec = 60
```

Autostart is intentionally narrow:

- Non-loopback endpoints are never auto-started, even with
  `--allow-remote-server`.
- Loopback URLs with a base path, such as `http://127.0.0.1:8080/v1`, are
  treated as user-managed endpoints.
- `kotoba doctor` reports runtime/autostart readiness but does not start a
  server.

If startup is not possible, translation fails with a startup hint and
`kotoba doctor` can be used to inspect config, runtime, server, memory,
glossary, and privacy status.

Kotoba uses the OpenAI-compatible `/v1/chat/completions` endpoint and a
`/health` endpoint for health checks.
