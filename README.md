# Kotoba CLI

Kotoba CLI is a local-first translation CLI written in Zig.

`kotoba` talks to a user-managed llama.cpp-compatible server. It does not bundle
or auto-start the runtime in v1.0.

```bash
llama-server -m /path/to/model.gguf --host 127.0.0.1 --port 8080
kotoba init --model-id custom --model-path /path/to/model.gguf --yes
kotoba translate "Hello world" --to ja
```

Translation requests are local-loopback only by default. Use
`--allow-remote-server` only when you explicitly accept sending text to a
non-local endpoint.

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
```

Markdown translation protects code spans, code fences, URLs, frontmatter, and
Markdown tables. Tables are intentionally left untranslated in v1.0 to avoid
breaking their structure.

Configuration follows XDG paths:

- `~/.config/kotoba/config.toml`
- `~/.config/kotoba/models.toml`
- `~/.config/kotoba/glossary.toml`
- `~/.local/share/kotoba/memory.sqlite3`
