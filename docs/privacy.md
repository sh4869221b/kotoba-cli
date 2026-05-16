# Privacy

Kotoba CLI is designed for local-first translation.

- Translation commands do not use cloud APIs.
- Translation commands talk only to the configured local loopback server by
  default.
- Non-loopback server endpoints are rejected with `server_not_local` unless the
  user explicitly passes `--allow-remote-server`.
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

The only network operation expected during normal translation is the request to
the configured llama.cpp-compatible server endpoint.
