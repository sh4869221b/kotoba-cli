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
kotoba translate [TEXT] [--from en|ja] [--to ja|en] [--mode default|technical] [--debug]
kotoba translate --file PATH --to ja|en [--output PATH] [--overwrite] [--debug]
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

### Side-effect ordering and read-only commands

Every command validates its complete argument shape before the first
persistent mutation: command and subcommand names, option names, required
values, argument counts, and known cross-option constraints are checked before
state is created or changed. Argument-shape validation errors return exit 2
with `invalid_arguments` and perform no persistent write. The no-selection form
of `init` intentionally prints model choices before returning this error, and
JSON error requests may report the error on stdout. `help` and `--help` are not
implemented in v1; they remain unsupported errors and do not initialize state.

The following commands are read-only inspections. They may still fail when
state is missing, malformed, inaccessible, or unsafe, and a failed inspection
does not repair or rewrite that state.

| Command | Missing-state behavior |
| --- | --- |
| `models list`, `models info ID`, `models verify [ID]` | A missing `models.toml` is represented by the built-in candidate list in memory only; no registry file or parent directory is created. The requested model may still be reported as unavailable. |
| `memory status` | A missing database prints `path: PATH` and `rows: 0` without creating the database or parent. An existing empty, malformed, schema-less, inaccessible, or unsafe database returns an error. |
| `glossary validate` | Reads and validates the glossary; it does not create or rewrite it. |
| `doctor` | Preserves diagnostics for missing or invalid state, including a missing memory database; it does not repair state. |
| `config get KEY`, `config list`, `version` | Reads or prints configuration metadata only. A missing config can still produce the existing initialization error for `config get`; `version` does not resolve XDG paths. |

The intentional persistent writers are `init`, `config set`, `models import`,
`models pull`, `models use`, `models remove`, and `memory clear --yes`.
Successful `translate` retains its normal writes to translation memory and a
requested output file. `models pull` is still the only command that can use
the network, and only when explicitly requested.

Configuration and model registry persistence use the
strict, intentionally small TOML subset documented in
[strict-toml.md](strict-toml.md). The implementation preserves
supported values semantically while rejecting malformed, unknown, duplicate,
and unsupported schema data. Missing state remains distinct from parse,
schema, native I/O, and allocation failures. The document also records the
existing canonical URL exception and the preflight boundary for state-changing
commands. This persistence contract does not promise full TOML conformance,
atomic config/registry writes, locking, rollback, or crash durability. Translation
output files use the separate staged-publication contract below.

Read-only memory and doctor checks preflight databases without concurrent
writers before opening SQLite. WAL mode and `-wal`/`-shm` sidecars, along with
rollback journals that could require recovery or cannot be classified safely,
fail with `sqlite_failed` without opening for recovery or changing any file.
Empty or zeroed rollback journals remain readable. This preflight is not a
concurrency guarantee. v1 adds no general transaction, locking, or schema
migration layer.

For `plain` and `markdown`, successful translate stdout is only translated
text. TTY detection must not enable extra output. Diagnostics are opt-in through
`--debug` or `log_level = "debug"` and go to stderr. JSON output remains the
only stdout format that includes metadata.

### Invocation ownership

Command adapters own temporary argument and parse graphs in short-lived arenas
where needed. `cli.run` owns the dispatch/XDG arena; `doctor.run` owns the
doctor diagnostic arena even when called directly. `main` releases its argv
arena before calling `process.exit`.

Translation is deliberately different at its return boundary: the adapter
passes the original caller allocator into `translate.run`, which returns an
independent `OwnedResult`. The adapter keeps that owner through rendering and
file publication, then deinitializes it. The result's text, optional source,
model/runtime strings, warning array, and warning strings are copied into the
owner; its serializer view cannot outlive it. This allocation contract does
not alter CLI strings, JSON fields, staged publication, persistence ordering,
or the storage atomicity limits above.

## Data Locations

Kotoba follows XDG directories:

- config: `~/.config/kotoba/config.toml`
- model registry: `~/.config/kotoba/models.toml`
- installed models: `~/.local/share/kotoba/models/`
- glossary: `~/.config/kotoba/glossary.toml`
- translation memory: `~/.local/share/kotoba/memory.sqlite3`
- cache: `~/.cache/kotoba/`
- state/logs: `~/.local/state/kotoba/`

## Text encoding contract

Translation text is valid UTF-8 and must not contain a NUL byte. This applies
to plain and Markdown input, glossary text, generated text, and accepted
translation-memory text. The contract preserves bytes: it does not normalize,
transcode, trim, repair, or replace accepted text. Empty and whitespace-only
text remain encoding-valid, as do a UTF-8 BOM, combining marks, supplementary
characters, and valid control characters U+0001 through U+001F.

Validation checks UTF-8 before NUL. A byte sequence containing both defects is
reported as `invalid_utf8`; otherwise an embedded NUL is reported as
`embedded_nul`. Both errors exit 1 and use the fixed messages `Text must be
valid UTF-8.` and `Text must not contain NUL bytes.` without including rejected
text in the diagnostic.

Generation validates the complete accepted byte sequence only after its finish
reason is accepted and before it is stored or accumulated. A timeout remains a
`timeout` error and context/decode failures remain `llama_decode_failed`, even
if their partial bytes are malformed. A selected legacy translation-memory row
that violates this contract is rejected without repairing, deleting, or
updating the row.

Direct, file, and stdin text is validated before language detection, including
when both language options are explicit. The complete glossary document is
validated before parsing, and borrowed segment/glossary text is checked before
segment work. Empty input still has its separate argument error; valid empty,
whitespace, partial, and token-limited generated results remain accepted.

SQLite transport copies text using its full byte length, not a NUL terminator.
Both selected legacy source and translation are validated before any hit-count
or timestamp update; rejection does not change rows or their bytes. This is a
selected-row check, not a scan, migration, or transaction/repair mechanism.
Success JSON validates every emitted variable string and escapes all controls
U+0001 through U+001F. Standard JSON decoding preserves the original text;
source remains omitted unless requested with `--include-source`.

Future MOD support treats a binary container as raw bytes and separately
extracts translation text for this validation. This document defines that
responsibility only; it does not add a MOD adapter or container format.

## Translation Flow

This section describes the **current v1 implementation flow**, not the target
architecture or commit protocol for the roadmap work. For future architecture,
hard dependencies, validation ordering, Translation Memory commit semantics, and
file/MOD publication ordering, Roadmap #46 and the referenced implementation
Issues are authoritative when they differ from this current-state description.

1. Read config and verify that a model is selected.
2. Read direct text, stdin, or file input.
3. Protect Markdown elements when translating Markdown.
4. Split input into translatable segments.
5. Check SQLite translation memory unless disabled.
6. Load the selected GGUF model into an embedded llama.cpp session.
7. Generate uncached translated segments in-process.
8. Restore protected Markdown tokens.
9. Save cacheable results and write plain, Markdown, or JSON output.

The broader roadmap target for file/MOD output is intentionally stricter:
generated candidates must pass the complete finish/detokenization/text/structure/content
validation pipeline (UTF-8/no-NUL text checks are already enforced), accepted
Translation Memory rows are staged in memory, the staged
artifact receives final validation, accepted rows are committed in a short
SQLite write transaction, and only then is the artifact atomically published.
Roadmap #46 and the referenced implementation Issues govern that future
pipeline. The current Issue #25 file-output implementation supplies only the
stage/finish/publish boundary, so do not infer that full validation and commit
protocol from the simplified current flow above.

### File publication contract (Issue #25)

Translation file output uses this filesystem contract. It does not describe a
Translation Memory transaction or the future validation pipeline.

The output primitive creates a named sibling stage exclusively in the
destination's parent directory. It opens and pins that parent for the stage,
validation, publish, and abort operations, so a replacement parent path cannot
redirect the operation. The stage is written to completion, then its actual
writer is flushed, synced, and closed through a checked close boundary. Only a
successful finish produces a read-only finished artifact. The caller validates
the exact finished bytes from that artifact; it must not rewrite the stage
between validation and publication.

Publication replaces the destination directory entry only after all caller
validation and any optional external commit gate succeeds. With overwrite,
the original entry remains until the atomic same-parent rename. Replacing a
symlink replaces the symlink entry and never follows or changes its target;
other hardlinks retain the old inode and its bytes. An existing regular
destination's permission mode is captured and preserved; an absent
destination uses the default creation mode `0666 & ~umask`. A no-overwrite
publish counts any existing entry, including a dangling symlink, and uses the
race-free `renamePreserve` no-replace operation. If that operation is
unsupported, publication fails closed and does not fall back to a check
followed by rename.

Write, flush, sync, checked-close, read-only validation, and publish failures
are primary errors and return a nonzero result. Failure cleanup is
best-effort and limited to the owned stage; a process kill or cleanup failure
can leave its uniquely named orphan. This contract does not promise directory
fsync, power-loss durability or recovery, ACL/xattr preservation, or owner
copying.

The primitive does not perform Translation Memory operations. A caller may
commit accepted rows after exact staged-byte validation and before publish. If
publish then fails, an already successful external commit cannot be undone by
this module; no compensating transaction or rollback is attempted here.

### Critical deletion failure contract (Issue #25)

Important model removal steps distinguish a missing path from an access or
other filesystem failure. A missing path can be an intentional no-op, but
realpath, reload, or deletion failures propagate as errors. Such a failure
returns nonzero and must not print the `removed` success line. If the registry
was already changed before a later reload or file operation fails, the
registry may remain changed while the model or config is unchanged; Issue #25
does not add a compensating registry transaction or #27 rollback.

The loader, defaults, and preflight rules remain the separate responsibility
of Issue #61. This output and deletion primitive does not broaden that
boundary or introduce a general transaction layer.

## Model Management

`kotoba models import` copies a local GGUF into the XDG data model directory and
registers it. `kotoba models pull` downloads a GGUF from a registered HTTPS
source, a direct HTTPS URL, or a Hugging Face repo/file selector. `models use`
selects a registered model, `models verify` checks file existence and checksum
when available, and `models remove ID --yes` deletes the managed model file
only when no other registry entry references the same file, then clears the
selection if it was active.

Remote model URLs are bounded to 8192 bytes and must be valid HTTPS URLs without
userinfo (including empty userinfo) or raw ASCII control characters. Validation
covers the complete input, including any fragment. An explicit signed URL is
used only for that request: its encoded query bytes are preserved exactly, and
its fragment is removed before acquisition. All query parameters, including an
empty query, are treated as transient; no credential-key allowlist is used.

The optional registry field `source_url` records only remote scheme, authority
without userinfo, and encoded path. It is display/provenance information, never
a download fallback. `download_url` retains only reusable query-free HTTPS URLs
(without fragments) or existing local/file sources. Local filenames containing
`?` or `#` are preserved. A fragment alone does not prevent HTTPS URL reuse.
Invalid remote metadata is displayed as `[redacted]` and saved as empty URL
fields; otherwise valid legacy userinfo/query URLs can retain a safe identity
but cannot become reusable URLs.

Registry reads, including `models info` and `doctor`, do not rewrite files.
Every successful registry write sanitizes all retained entries, including
unrelated legacy entries, without changing installed paths, IDs, or checksums
and without creating secret backups or sidecars. Doctor warns about unsafe
remote metadata across the whole registry, even without a usable config.
Earlier external backups and history are not erased by this migration.

`models pull ID` requires a reusable source before acquisition or verification,
even if an installed file exists. Query-bearing legacy sources and models with
only `source_url` require a fresh explicit `--model-url`, ID, and checksum;
invalid/userinfo remote sources are rejected. `models use` and `models verify`
continue to use installed paths. URL-path secrets cannot be recognized
automatically; do not supply them. CLI arguments may also appear in shell
history or process inspection.

`kotoba init` only selects an existing local registry path or records an
explicit `--model-path`; it never acquires a model. A URL-only or missing-path
registry entry makes `init --model-id ID` exit 1 with instructions to run
`kotoba models pull ID --use` first or provide `--model-path PATH`. This
replaces the earlier implicit acquisition of URL-only registry entries.

## Markdown Limitations

Kotoba protects code fences, inline code, URLs, frontmatter, HTML-like tags, and
Markdown table lines. Tables are restored unchanged in v1 to avoid corrupting
cell separators, escapes, links, and inline code.
