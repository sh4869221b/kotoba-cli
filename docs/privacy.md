# Privacy

Kotoba CLI is designed for local-first translation.

- Translation commands do not use cloud APIs.
- Translation commands run through the embedded llama.cpp engine in the current
  process.
- GGUF model files are selected from local paths recorded in the model registry.
- Normal translation performs no network request.
- Network access can occur only when the user explicitly runs
  `kotoba models pull` for an HTTPS model source.
- `kotoba init` never downloads a model. It selects an existing local registry
  path or accepts an explicit `--model-path`; use `kotoba models pull ID --use`
  before initializing a registered downloadable model.
- A URL-only registry entry now makes `init --model-id ID` exit 1 with an
  explicit-pull/local-path instruction. This is a setup boundary, not an
  operating-system-wide network sandbox.
- `kotoba translate` suppresses diagnostics by default; interactive terminal
  use still prints only translated text for plain and Markdown output.
- Debug output is opt-in and is written to stderr. It must not include source or
  translated bodies.
- JSON output omits `source_text` unless `--include-source` is specified.
- Logs do not persist source or translated bodies by default.
- SQLite translation memory stores source and translated text when enabled.

## Model URL metadata and migration

Remote model URLs containing userinfo, including an empty userinfo, are rejected
for acquisition. When the user explicitly supplies `--model-url`, its encoded
query bytes are used exactly for that request and its fragment is removed before
acquisition. All remote query content is transient, including an empty query;
queries and fragments are not persisted in the registry.

`source_url` is informational provenance. It contains only the remote scheme,
authority without userinfo, and encoded path, and is never a download fallback.
For remote sources, only a query-free HTTPS URL can remain reusable in
`download_url`; local and file sources remain usable as recorded, including
literal `?` or `#` characters in local filenames. A credential-bearing or
query-bearing remote source must be entered again with a fresh URL. A pull that
needs resupply also requires the model ID and checksum:

```bash
kotoba models pull --model-url https://download.example.invalid/models/model.gguf \
  --id MODEL_ID --checksum SHA256
```

When no reusable `download_url` remains, `models pull MODEL_ID` reports that a
reusable download URL is required before it acquires or verifies anything, even
when the installed file still exists.
`models use` and `models verify` use the installed path and do not need a
download URL.

Registry reads (`models info`, `models list`, and `doctor`) do not rewrite old
files. The next successful registry write sanitizes every retained entry, not
only the entry being changed. No secret backup or sidecar is created; copies in
external backups or history are outside Kotoba's control and are not erased.
Command-line arguments can appear in shell history or process inspection. URL
path components that happen to be sensitive are outside automatic detection, so
do not supply secret-looking paths.

As a manual migration alternative, preserve each model's `id`, installed `path`,
`checksum`, and other descriptive fields. For a credential-bearing or
query-bearing URL, clear `download_url` and retain only a safe identity in
`source_url`:

```toml
download_url = ""
source_url = "https://download.example.invalid/models/model%2Bname.gguf"
```

This `source_url` is display/provenance metadata, not a fetch URL. Run
`kotoba doctor` to confirm the result, and provide a fresh `--model-url`, ID, and
checksum for a later download. Do not persist credentials in any new file.

Use `--no-memory` for one command when translating sensitive text:

```bash
kotoba translate "private text" --to ja --no-memory
```

To disable translation memory persistently:

```bash
kotoba config set memory_enabled false
```
