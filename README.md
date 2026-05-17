# Kotoba CLI

Kotoba CLI is a local-first translation CLI written in Zig.

`kotoba` talks to a local llama.cpp-compatible server. By default it reuses an
already-running loopback server, or starts `llama-server` for the current command
when `runtime = "llama_server"`, `server_autostart = true`, `server_url` is a
root loopback URL, `llama-server` is available on `PATH`, and `model_path`
points to a model.

```bash
kotoba init --model-id custom --model-path /path/to/model.gguf --yes
kotoba translate "Hello world" --to ja
```

Translation requests are local-loopback only by default. Use
`--allow-remote-server` only when you explicitly accept sending text to a
non-local endpoint. Remote endpoints are never auto-started.

JSON output omits source text unless `--include-source` is specified. Translation
memory stores source and translated text unless memory is disabled.

## Commands

```bash
kotoba init [--server-url URL] [--model-id ID] [--model-path PATH] [--skip-download] [--yes]
kotoba translate [TEXT] --to ja
kotoba translate --file README.md --to ja
cat README.md | kotoba translate --to ja --format markdown
kotoba doctor
kotoba models list
kotoba memory status
kotoba glossary validate
kotoba config get server_url
kotoba config set llama_server_path /path/to/llama-server
```

Markdown translation protects code spans, code fences, URLs, frontmatter, and
Markdown tables. Tables are intentionally left untranslated in v1.0 to avoid
breaking their structure.

Configuration follows XDG paths:

- `~/.config/kotoba/config.toml`
- `~/.config/kotoba/models.toml`
- `~/.config/kotoba/glossary.toml`
- `~/.local/share/kotoba/memory.sqlite3`

Runtime-related config keys:

- `runtime = "llama_server"`
- `server_autostart = true`
- `llama_server_path = "llama-server"`
- `server_startup_timeout_sec = 60`
