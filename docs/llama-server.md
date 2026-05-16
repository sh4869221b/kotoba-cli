# llama.cpp Server Setup

Kotoba v1 expects a llama.cpp-compatible server to be started separately. It
does not bundle, install, start, or stop the runtime.

Example:

```bash
llama-server -m /path/to/model.gguf --host 127.0.0.1 --port 8080
```

Then initialize Kotoba with the same endpoint and model path:

```bash
kotoba init --server-url http://127.0.0.1:8080 --model-id custom --model-path /path/to/model.gguf --yes --skip-download
```

If the server is not running, translation fails with a startup hint and
`kotoba doctor` can be used to inspect config, server, memory, glossary, and
privacy status.

Kotoba uses the OpenAI-compatible `/v1/chat/completions` endpoint and a
`/health` endpoint for health checks.
