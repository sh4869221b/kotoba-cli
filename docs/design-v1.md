# Kotoba CLI v1 Design

Kotoba CLI is a Zig CLI for local-first translation. The executable is
`kotoba`, and v1 targets English to Japanese and Japanese to English
translation only.

## Goals

- Translate direct text, stdin, text files, and Markdown files.
- Run translation in-process through embedded llama.cpp.
- Keep translation-time operation local.
- Manage local GGUF models through `kotoba models ...`.
- Preserve Markdown structure conservatively.
- Reuse translations through SQLite translation memory.
- Provide machine-readable JSON output for tool integration.

## Non-Goals

- Cloud translation APIs or cloud LLM backends.
- Bundling GGUF model files into the executable.
- GUI, OCR, audio, subtitle-specific optimization, or batch directory
  translation.
- Markdown table translation in v1.

## Command Contract

```text
kotoba init [--model-id ID] [--model-path PATH] [--yes]
kotoba translate [TEXT] [--from en|ja] [--to ja|en] [--mode default|technical]
kotoba translate --file PATH --to ja|en [--output PATH] [--overwrite]
kotoba doctor [--format json]
kotoba config list
kotoba config get KEY
kotoba config set KEY VALUE
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
kotoba memory clear --yes
kotoba glossary validate
kotoba version
```

## Data Locations

Kotoba follows XDG directories:

- config: `~/.config/kotoba/config.toml`
- model registry: `~/.config/kotoba/models.toml`
- installed models: `~/.local/share/kotoba/models/`
- glossary: `~/.config/kotoba/glossary.toml`
- translation memory: `~/.local/share/kotoba/memory.sqlite3`
- cache: `~/.cache/kotoba/`
- state/logs: `~/.local/state/kotoba/`

## Translation Flow

1. Read config and verify that a model is selected.
2. Read direct text, stdin, or file input.
3. Protect Markdown elements when translating Markdown.
4. Split input into translatable segments.
5. Check SQLite translation memory unless disabled.
6. Load the selected GGUF model into an embedded llama.cpp session.
7. Generate uncached translated segments in-process.
8. Restore protected Markdown tokens.
9. Save cacheable results and write plain, Markdown, or JSON output.

## Model Management

`kotoba models import` copies a local GGUF into the XDG data model directory and
registers it. `kotoba models pull` downloads a GGUF from a registered HTTPS
source, a direct HTTPS URL, or a Hugging Face repo/file selector. `models use`
selects a registered model, `models verify` checks file existence and checksum
when available, and `models remove ID --yes` deletes the managed model file
only when no other registry entry references the same file, then clears the
selection if it was active.

## Markdown Limitations

Kotoba protects code fences, inline code, URLs, frontmatter, HTML-like tags, and
Markdown table lines. Tables are restored unchanged in v1 to avoid corrupting
cell separators, escapes, links, and inline code.
