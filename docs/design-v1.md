# Kotoba CLI v1 Design

Kotoba CLI is a Zig CLI for local-first translation. The executable is
`kotoba`, and v1 targets English to Japanese and Japanese to English
translation only.

## Goals

- Translate direct text, stdin, text files, and Markdown files.
- Use a user-managed llama.cpp-compatible server.
- Keep translation-time requests local by default.
- Preserve Markdown structure conservatively.
- Reuse translations through SQLite translation memory.
- Provide machine-readable JSON output for tool integration.

## Non-Goals

- Bundling or auto-starting llama.cpp.
- Cloud translation APIs or cloud LLM backends.
- GUI, OCR, audio, subtitle-specific optimization, or batch directory
  translation.
- Markdown table translation in v1.

## Command Contract

```text
kotoba init [--server-url URL] [--model-id ID] [--model-path PATH] [--skip-download] [--yes]
kotoba translate [TEXT] [--from en|ja] [--to ja|en] [--mode default|technical]
kotoba translate --file PATH --to ja|en [--output PATH] [--overwrite]
kotoba doctor [--format plain|json]
kotoba config get KEY
kotoba config set KEY VALUE
kotoba models list
kotoba memory status
kotoba memory clear --yes
kotoba glossary validate
kotoba version
```

## Data Locations

Kotoba follows XDG directories:

- config: `~/.config/kotoba/config.toml`
- model candidates: `~/.config/kotoba/models.toml`
- glossary: `~/.config/kotoba/glossary.toml`
- translation memory: `~/.local/share/kotoba/memory.sqlite3`
- cache: `~/.cache/kotoba/`
- state/logs: `~/.local/state/kotoba/`

## Translation Flow

1. Read config and validate the server endpoint.
2. Read direct text, stdin, or file input.
3. Protect Markdown elements when translating Markdown.
4. Split input into translatable segments.
5. Check SQLite translation memory unless disabled.
6. Send uncached segments to the llama server.
7. Restore protected Markdown tokens.
8. Save cacheable results and write plain, Markdown, or JSON output.

## Markdown Limitations

Kotoba protects code fences, inline code, URLs, frontmatter, HTML-like tags, and
Markdown table lines. Tables are restored unchanged in v1 to avoid corrupting
cell separators, escapes, links, and inline code.
