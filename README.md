# Kotoba CLI

Kotoba CLI is a local-first translation CLI written in Zig. It embeds the
llama.cpp inference engine and runs translation in-process against a selected
local GGUF model.

```bash
kotoba models import --id local-ja --path /path/to/model.gguf --use
kotoba translate "Hello world" --to ja
```

Normal translation performs no network request. Network access is used only
when you explicitly run `kotoba models pull` for an HTTPS model source.

JSON output omits source text unless `--include-source` is specified.
Translation memory stores source and translated text unless memory is disabled.

## Output Contract

`kotoba translate` is quiet by default. For `plain` and `markdown` output,
stdout contains only the translated text, even when running interactively in a
terminal. Diagnostics, model-load details, and progress output are suppressed
unless debug output is explicitly requested.

Use `--format json` when callers need metadata such as cache status, warnings,
runtime, or elapsed time. Use `--debug` only when diagnosing runtime behavior;
debug output may be written to stderr and never changes translated stdout.

## Commands

```bash
kotoba init [--model-id ID] [--model-path PATH] [--yes]
kotoba translate [TEXT] --to ja [--debug]
kotoba translate --file README.md --to ja [--debug]
cat README.md | kotoba translate --to ja --format markdown [--debug]
kotoba doctor
kotoba config list
kotoba config get model_path
kotoba config set max_tokens 512
kotoba models list
kotoba models info ID
kotoba models import --id ID --path PATH [--name NAME] [--checksum SHA256] [--use]
kotoba models pull ID [--output PATH] [--use]
kotoba models pull --hf-repo USER/MODEL[:QUANT] [--hf-file FILE] [--id ID] [--use]
kotoba models pull --model-url HTTPS_URL --id ID --checksum SHA256 [--use]
kotoba models use ID
kotoba models verify [ID]
kotoba models remove ID --yes
kotoba memory status
kotoba glossary validate
```

## Build

Initialize the pinned llama.cpp submodule before building from a fresh clone:

```bash
git submodule update --init --recursive
zig build
```

The embedded llama.cpp build is verified on Linux and has native macOS linker
handling; other hosts are not wired yet.

Markdown translation protects code spans, code fences, URLs, frontmatter, and
Markdown tables. Tables are intentionally left untranslated in v1.0 to avoid
breaking their structure.

Configuration follows XDG paths:

- `~/.config/kotoba/config.toml`
- `~/.config/kotoba/models.toml`
- `~/.config/kotoba/glossary.toml`
- `~/.local/share/kotoba/models/`
- `~/.local/share/kotoba/memory.sqlite3`

Embedded runtime config keys include:

- `model_id`
- `model_path`
- `context_length`
- `threads`
- `max_tokens`
- `temperature`
- `timeout_sec`
