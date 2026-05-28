# Privacy

Kotoba CLI is designed for local-first translation.

- Translation commands do not use cloud APIs.
- Translation commands run through the embedded llama.cpp engine in the current
  process.
- GGUF model files are selected from local paths recorded in the model registry.
- Normal translation performs no network request.
- Network access can occur only when the user explicitly runs
  `kotoba models pull` for an HTTPS model source.
- `kotoba translate` suppresses diagnostics by default; interactive terminal
  use still prints only translated text for plain and Markdown output.
- Debug output is opt-in and is written to stderr. It must not include source or
  translated bodies.
- JSON output omits `source_text` unless `--include-source` is specified.
- Logs do not persist source or translated bodies by default.
- SQLite translation memory stores source and translated text when enabled.

Use `--no-memory` for one command when translating sensitive text:

```bash
kotoba translate "private text" --to ja --no-memory
```

To disable translation memory persistently:

```bash
kotoba config set memory_enabled false
```
