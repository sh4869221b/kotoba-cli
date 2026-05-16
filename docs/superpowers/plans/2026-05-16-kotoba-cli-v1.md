# Kotoba CLI v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `kotoba`, a Zig-based local translation CLI that talks to a user-managed llama.cpp-compatible server and supports config, model selection, glossary, SQLite translation memory, Markdown-safe translation, JSON/plain/markdown output, and diagnostics for v1.0.

**Architecture:** Keep the CLI binary thin and route behavior through small modules: config/model/glossary loading, input parsing, prompt construction, llama server adapter, translation memory, Markdown protection, and output formatting. The v1.0 runtime is external: `kotoba` never embeds or auto-starts inference, and translation-time network access is limited to the configured local server endpoint.

**Tech Stack:** Zig 0.16.0, Zig standard library HTTP/JSON/fs APIs, C SQLite via system `sqlite3` for translation memory, minimal project-owned TOML parser/writer for controlled config files, llama.cpp OpenAI-compatible `/v1/chat/completions` adapter.

---

## Current Repository Assumptions

- The repository at `/home/sh4869/ghq/github.com/sh4869221b/kotoba-cli` is effectively empty.
- No repo-local `AGENTS.md`, `CONTRIBUTING.md`, `README.md`, `build.zig`, or source tree exists yet.
- `zig version` is `0.16.0`.
- System SQLite is available through `/usr/bin/sqlite3` and `pkg-config --modversion sqlite3` reports `3.53.0`.
- Initialize Git before implementation if the `.git` directory remains empty or invalid.

## Scope Boundaries

Implement in v1.0:
- `kotoba init`, `translate`, `doctor`, `version`
- Minimal `models`, `memory`, `glossary`, and `config` subcommand surfaces sufficient for MVP inspection/toggling
- en -> ja and ja -> en only
- plain/json/markdown output
- stdin, direct text, and `--file`
- Markdown structure protection including whole-table protection
- SQLite translation memory with persistent and one-shot disable controls
- `kotoba init` completes the v1.0 setup path: config/model/glossary files, model selection, optional download, checksum verification, memory DB initialization, server check, and a small test translation when the server is reachable
- Translation-time server connections are local-only by default to preserve the no-external-network guarantee

Do not implement in v1.0:
- Bundled llama.cpp runtime
- Server auto-start
- Cloud APIs
- Ollama adapter
- Markdown table translation
- Streaming output
- Project-local config layering
- GUI, OCR, subtitle-specific logic, batch directory translation

## Proposed File Structure

- `build.zig`: build executable, tests, and SQLite link settings.
- `build.zig.zon`: package metadata.
- `README.md`: v1.0 usage, llama server prerequisite, privacy notes.
- `AGENTS.md`: repo-local implementation rules if needed.
- `src/main.zig`: executable entrypoint and top-level error handling.
- `src/cli.zig`: command and option parsing.
- `src/errors.zig`: stable error codes and human/JSON rendering helpers.
- `src/xdg.zig`: XDG directory resolution.
- `src/config.zig`: `config.toml` data model, defaults, load/save.
- `src/models.zig`: `models.toml` data model, default template, selection validation.
- `src/glossary.zig`: glossary data model, hash, prompt entries.
- `src/toml.zig`: minimal TOML parser/writer for this project's config shapes.
- `src/input.zig`: direct argument/stdin/file reading and input kind detection.
- `src/lang.zig`: en/ja validation and simple source-language detection.
- `src/prompt.zig`: default/technical translation prompt builder.
- `src/llama.zig`: llama.cpp-compatible server health and chat completion calls.
- `src/translate.zig`: translation orchestrator and segment result model.
- `src/segment.zig`: paragraph/list/Markdown segment model.
- `src/markdown.zig`: Markdown protection and restoration.
- `src/memory.zig`: SQLite schema, lookup, insert/update, clear/stats.
- `src/output.zig`: plain/json/markdown output formatting.
- `src/doctor.zig`: config/model/server/memory/glossary/privacy diagnostics.
- `test/fixtures/`: Markdown, TOML, and fake server response fixtures.
- `test/integration/`: required fake-local-server smoke tests for v1.0 completion.

## Dependency Policy

- Start with zero Zig package dependencies.
- Use Zig stdlib for CLI parsing, JSON, HTTP, file IO, hashing, and time.
- Use C SQLite through `@cImport` and `linkSystemLibrary("sqlite3")`.
- If a third-party Zig package becomes necessary, pause and get explicit approval before adding it.

## Model Candidate Policy

- v1.0 does not embed a real third-party model URL unless the model source, license, checksum, and redistribution/reference terms have been verified.
- The generated `models.toml` should therefore contain a documented example entry and a `custom` local-model path flow.
- `kotoba init` must support selecting a custom local model immediately, and it must support downloading a user-provided `download_url` entry from `models.toml`.
- If no downloadable recommended model is configured, interactive init should present "custom local model" and "configure later" as the actionable choices instead of pretending that a bundled lightweight candidate can be fetched.

## Command Contract

Initial command surface:

```text
kotoba init [--server-url URL] [--model-id ID] [--model-path PATH] [--skip-download] [--yes] [--allow-remote-server]
kotoba translate [TEXT] [--from en|ja] [--to ja|en] [--mode default|technical] [--format plain|json|markdown] [--include-source] [--file PATH] [--output PATH] [--overwrite] [--no-memory] [--no-glossary] [--allow-remote-server]
kotoba doctor [--format plain|json]
kotoba config get [KEY]
kotoba config set KEY VALUE
kotoba models list
kotoba memory status
kotoba memory clear [--yes]
kotoba glossary validate
kotoba version
```

`models`, `memory`, `glossary`, and `config` can remain intentionally small for v1.0 as long as the MVP needs are covered.

Language option precedence:

- Explicit `--from` and `--to` win.
- If only `--to` is set, infer `--from` from the input text.
- If `--to` is omitted, use `default_target_lang` from config.
- If `--from` is omitted after applying config defaults, infer it from input.
- Same-language pairs are invalid unless a future mode explicitly supports rewrite behavior.
- The v1.0 default target language is `ja`; `default_source_lang` is unset by default so source inference is used unless configured.

Server endpoint policy:

- During translation and file translation, accept local loopback hosts by default: `127.0.0.1`, `localhost`, and `::1`.
- If `server_url` points to a non-loopback host, fail with `server_not_local` unless `--allow-remote-server` or a future explicit config opt-in is set.
- Keep `init` model downloads separate from translation-time server requests so the no-external-network translation guarantee remains testable.

## Error Codes

Reserve stable string codes early:

- `not_initialized`
- `config_invalid`
- `models_invalid`
- `model_missing`
- `checksum_failed`
- `server_unreachable`
- `server_bad_response`
- `timeout`
- `markdown_parse_failed`
- `output_exists`
- `sqlite_failed`
- `glossary_invalid`
- `unsupported_language_pair`
- `server_not_local`
- `invalid_arguments`

JSON mode should emit structured errors with `code`, `message`, `hints`, and no source text unless `--include-source` is explicitly set and the failure occurs after input parsing.

---

## Task 1: Repository Bootstrap

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/main.zig`
- Create: `src/cli.zig`
- Create: `src/errors.zig`
- Create: `README.md`

- [ ] **Step 1: Initialize Git if needed**

Run:

```bash
git status --short --branch
```

Expected if not initialized: failure similar to `fatal: not a git repository`.

If Git is invalid or absent, run:

```bash
git init
git branch -M main
```

- [ ] **Step 2: Create the minimal Zig executable**

Add a `build.zig` that builds an executable named `kotoba` and exposes `zig build test`.

`src/main.zig` should call into `cli.run` and convert returned errors into stderr messages plus exit codes.

- [ ] **Step 3: Write CLI smoke tests**

In `src/cli.zig`, add unit tests for:

- `kotoba version`
- unknown command
- missing command

Run:

```bash
zig build test
```

Expected: tests pass.

- [ ] **Step 4: Add README bootstrap documentation**

Document:

- This is local-only translation CLI.
- llama.cpp-compatible server must be started separately.
- Initial implementation target is v1.0 MVP.

- [ ] **Step 5: Commit**

```bash
git add build.zig build.zig.zon src README.md
git commit -m "chore: bootstrap Zig CLI project"
```

---

## Task 2: CLI Parser and Command Model

**Files:**
- Modify: `src/cli.zig`
- Modify: `src/errors.zig`
- Test: `src/cli.zig`

- [ ] **Step 1: Define parsed command structs**

Create structs/enums for:

- `Command`
- `TranslateOptions`
- `InitOptions`
- `DoctorOptions`
- `OutputFormat`
- `TranslateMode`
- `Language`

- [ ] **Step 2: Add failing parser tests**

Cover:

- `translate "Hello" --to ja`
- `translate --file README.md --to ja`
- stdin-oriented `translate --to en`
- config-default-oriented `translate "Hello"` with no `--to`
- `--from en --to ja`
- `--format json --include-source`
- `--allow-remote-server`
- `init --server-url https://example.com --allow-remote-server --skip-download --yes`
- invalid language
- invalid format
- `--no-memory`

Run:

```bash
zig build test --summary all
```

Expected: parser tests fail until implementation is added.

- [ ] **Step 3: Implement parser without third-party dependencies**

Use a simple positional scanner because the command surface is small.

Rules:

- One direct text positional argument allowed for `translate`.
- `--file` and direct text are mutually exclusive.
- `--to` accepts only `ja` or `en` when present.
- `--from` accepts only `ja` or `en`.
- `--format` accepts `plain`, `json`, `markdown`.
- `--mode` accepts `default`, `technical`.
- `--allow-remote-server` is parsed but should be treated as a privacy-sensitive opt-in by the translation layer.

- [ ] **Step 4: Verify**

Run:

```bash
zig build test
```

Expected: all parser tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/cli.zig src/errors.zig
git commit -m "feat: add command parser"
```

---

## Task 3: XDG Paths and Config TOML

**Files:**
- Create: `src/xdg.zig`
- Create: `src/config.zig`
- Create: `src/toml.zig`
- Modify: `src/main.zig`
- Test: `src/xdg.zig`, `src/config.zig`, `src/toml.zig`

- [ ] **Step 1: Define XDG path behavior**

Paths:

- Config: `$XDG_CONFIG_HOME/kotoba/config.toml` or `~/.config/kotoba/config.toml`
- Models list: `$XDG_CONFIG_HOME/kotoba/models.toml`
- Glossary: `$XDG_CONFIG_HOME/kotoba/glossary.toml`
- Data: `$XDG_DATA_HOME/kotoba` or `~/.local/share/kotoba`
- Memory: data dir + `memory.sqlite3`
- Cache: `$XDG_CACHE_HOME/kotoba`
- State: `$XDG_STATE_HOME/kotoba` or `~/.local/state/kotoba`

- [ ] **Step 2: Add XDG tests using temporary environment inputs**

Test explicit env vars and fallback home-based paths.

- [ ] **Step 3: Implement minimal TOML support**

Support only what this project writes and reads:

- string
- integer
- boolean
- arrays of strings
- array-of-table style for models/glossary if needed
- comments are ignored

Do not implement a general TOML parser beyond v1.0 needs.

- [ ] **Step 4: Implement config defaults**

Defaults:

```toml
default_source_lang = ""
default_target_lang = "ja"
default_mode = "default"
default_output = "plain"
runtime = "llama_server"
server_url = "http://127.0.0.1:8080"
timeout_sec = 120
memory_enabled = true
glossary_enabled = true
privacy_mode = true
log_level = "warn"
```

- [ ] **Step 5: Verify**

Run:

```bash
zig build test
```

Expected: config round-trip tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/xdg.zig src/config.zig src/toml.zig src/main.zig
git commit -m "feat: add XDG config loading"
```

---

## Task 4: Models, Glossary, and Init Skeleton

**Files:**
- Create: `src/models.zig`
- Create: `src/glossary.zig`
- Modify: `src/cli.zig`
- Modify: `src/main.zig`
- Modify: `README.md`
- Test: `src/models.zig`, `src/glossary.zig`

- [ ] **Step 1: Add model and glossary fixtures**

Create fixture strings in unit tests for:

- one recommended default model
- one custom local model
- glossary `prefer`
- glossary `protect`

- [ ] **Step 2: Implement `models.toml` parsing and template generation**

Use the design fields:

```toml
[[models]]
id = "example-light"
name = "Example Light Model"
profile = "default"
languages = ["en", "ja"]
format = "gguf"
quantization = "Q4_K_M"
context_length = 4096
size = "small"
download_url = ""
checksum = ""
license = ""
recommended = true
notes = "Replace with a real local model entry."
```

Keep URLs empty in the default template unless the project has a verified recommended model source and license.

The generated template should make this explicit in comments or notes:

- built-in example entries are placeholders
- users can edit `models.toml` to add a downloadable model
- custom local model path is the reliable v1.0 setup path

- [ ] **Step 3: Implement glossary parsing and hash**

Glossary item shape:

```toml
[[terms]]
source = "CLI"
target = "CLI"
mode = "protect"
comment = "Do not translate command-line interface abbreviation."
```

Hash normalized term content for translation-memory cache keys.

- [ ] **Step 4: Implement non-interactive init path**

`kotoba init --server-url http://127.0.0.1:8080 --model-id custom --model-path /path/model.gguf --yes`

Should:

- create XDG dirs
- write missing `models.toml`
- write `config.toml`
- write missing `glossary.toml`
- initialize memory DB once Task 7 exists; until then, print that memory initialization is pending or no-op behind a stub

- [ ] **Step 5: Add full init completion task marker**

This task intentionally creates the early init scaffolding. Add a tracked TODO in code or docs that points to Task 7 and Task 13 for finishing:

- memory DB initialization after SQLite exists
- model download when `download_url` is configured and `--skip-download` is not set
- checksum verification when `checksum` is configured
- server health check after config is written
- small test translation when server health succeeds

Do not mark v1.0 init complete until these are implemented and tested.

- [ ] **Step 6: Verify**

Run:

```bash
zig build test
```

Then run with temp XDG dirs:

```bash
XDG_CONFIG_HOME=/tmp/kotoba-test-config XDG_DATA_HOME=/tmp/kotoba-test-data zig build run -- init --server-url http://127.0.0.1:8080 --model-id custom --model-path /tmp/model.gguf --yes
```

Expected: config files are created. Do not require the model path to exist yet unless `doctor` is running.

- [ ] **Step 7: Commit**

```bash
git add src/models.zig src/glossary.zig src/cli.zig src/main.zig README.md
git commit -m "feat: add init config scaffolding"
```

---

## Task 5: Language Detection, Prompt Builder, and Segment Model

**Files:**
- Create: `src/lang.zig`
- Create: `src/prompt.zig`
- Create: `src/segment.zig`
- Test: `src/lang.zig`, `src/prompt.zig`, `src/segment.zig`

- [ ] **Step 1: Add language direction tests**

Cover:

- explicit `en -> ja`
- explicit `ja -> en`
- `--to ja` with ASCII-heavy text infers `en`
- `--to en` with kana/kanji text infers `ja`
- no `--to` uses `default_target_lang` from config before source inference
- no `--from` uses source inference after config defaults are applied
- unsupported same-language pair fails

- [ ] **Step 2: Implement simple detector**

Use a lightweight heuristic:

- If text contains Hiragana, Katakana, or CJK unified ideographs, classify as `ja`.
- Otherwise classify as `en`.

Only use this when `--from` is omitted.

- [ ] **Step 3: Add prompt snapshot tests**

Test:

- default en -> ja
- technical ja -> en
- glossary prefer/protect instructions
- protected token instruction

- [ ] **Step 4: Implement prompt builder**

The prompt should instruct:

- translate only
- preserve protected tokens exactly
- no commentary
- respect glossary entries
- technical mode preserves identifiers, code, commands, Markdown structure

- [ ] **Step 5: Implement initial segmentation**

For plain text:

- short direct text: one segment
- stdin/txt: split on blank-line paragraph boundaries
- preserve blank separators for restoration

- [ ] **Step 6: Verify and commit**

```bash
zig build test
git add src/lang.zig src/prompt.zig src/segment.zig
git commit -m "feat: add translation prompt planning"
```

---

## Task 6: Llama Server Adapter

**Files:**
- Create: `src/llama.zig`
- Modify: `src/errors.zig`
- Test: `src/llama.zig`

- [ ] **Step 1: Define adapter interface**

Functions:

- `healthCheck(allocator, server_url, timeout_sec) !HealthStatus`
- `translateSegment(allocator, request) !TranslatedSegment`
- `validateLocalServerUrl(server_url, allow_remote_server) !void`

- [ ] **Step 2: Add JSON parsing tests from fixture strings**

Cover an OpenAI-compatible response:

```json
{
  "choices": [
    {
      "message": {
        "content": "こんにちは世界"
      }
    }
  ]
}
```

Also cover malformed response and empty choices.

- [ ] **Step 3: Add endpoint privacy tests**

Cover:

- `http://127.0.0.1:8080` accepted
- `http://localhost:8080` accepted
- `http://[::1]:8080` accepted
- `http://192.168.1.10:8080` rejected by default with `server_not_local`
- `https://example.com/v1` rejected by default with `server_not_local`
- non-loopback hosts accepted only when `allow_remote_server` is true

- [ ] **Step 4: Implement request construction**

Use `POST {server_url}/v1/chat/completions` with:

- `model`: configured model id if server needs it
- `messages`: system and user prompts
- `temperature`: low value such as `0.2`

- [ ] **Step 5: Implement server-unreachable and server-not-local hints**

Human output should include:

- configured `server_url`
- example command:

```bash
llama-server -m /path/to/model.gguf --host 127.0.0.1 --port 8080
```

- `kotoba doctor`
- `kotoba config set server_url ...`
- for `server_not_local`, explain that translation is local-only by default and requires `--allow-remote-server` for an explicit privacy opt-in

- [ ] **Step 6: Verify unit tests**

```bash
zig build test
```

Manual live-server translation remains a later integration step.

- [ ] **Step 7: Commit**

```bash
git add src/llama.zig src/errors.zig
git commit -m "feat: add llama server adapter"
```

---

## Task 7: SQLite Translation Memory

**Files:**
- Create: `src/memory.zig`
- Modify: `build.zig`
- Modify: `src/config.zig`
- Test: `src/memory.zig`

- [ ] **Step 1: Link SQLite**

Update `build.zig`:

- `exe.linkLibC()`
- `exe.linkSystemLibrary("sqlite3")`
- same for tests that import memory

- [ ] **Step 2: Define schema**

Use a table like:

```sql
CREATE TABLE IF NOT EXISTS translations (
  source_hash TEXT NOT NULL,
  source_text TEXT NOT NULL,
  translated_text TEXT NOT NULL,
  source_lang TEXT NOT NULL,
  target_lang TEXT NOT NULL,
  mode TEXT NOT NULL,
  model_id TEXT NOT NULL,
  glossary_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  hit_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_hash, source_lang, target_lang, mode, model_id, glossary_hash)
);
```

- [ ] **Step 3: Add memory tests**

Use a temporary SQLite file under `/tmp`.

Cover:

- DB initialization
- miss
- insert
- hit increments `hit_count`
- model id changes cause miss
- glossary hash changes cause miss

- [ ] **Step 4: Implement no-memory behavior**

The orchestrator will later pass a memory policy:

- config disabled: do not open DB
- `--no-memory`: do not open DB and do not write
- enabled: lookup before server call, upsert after successful translation

- [ ] **Step 5: Verify**

```bash
zig build test
```

Expected: SQLite tests pass and do not write outside temp paths.

- [ ] **Step 6: Commit**

```bash
git add build.zig src/memory.zig src/config.zig
git commit -m "feat: add SQLite translation memory"
```

---

## Task 8: Translation Orchestrator and Output Formatting

**Files:**
- Create: `src/translate.zig`
- Create: `src/output.zig`
- Create: `src/input.zig`
- Modify: `src/main.zig`
- Modify: `src/cli.zig`
- Test: `src/translate.zig`, `src/output.zig`, `src/input.zig`

- [ ] **Step 1: Define a fake translator interface for tests**

Do not require a real server for orchestrator tests. Create a test-only fake that maps known text to known output.

- [ ] **Step 2: Add orchestrator tests**

Cover:

- direct text translation
- stdin/file text passed as content
- memory hit avoids translator call
- memory miss calls translator then writes memory
- partial memory hit reports `cache_status = "partial"`
- full memory hit reports `cache_status = "full"`
- no memory hit reports `cache_status = "none"`
- `--no-memory` avoids lookup and write
- unsupported direction fails before server call
- non-loopback `server_url` fails before server call unless `--allow-remote-server` is set

- [ ] **Step 3: Implement input reader**

Rules:

- direct text wins over stdin only when explicit text is provided
- `--file` reads file and sets input kind from extension
- no direct text and no file reads stdin
- empty input returns `invalid_arguments`

- [ ] **Step 4: Implement output formatter**

Plain:

- translated text only

JSON:

- `source_lang`
- `target_lang`
- `mode`
- `model_id`
- `runtime`
- `server_url`
- `cached`: true only when all segments are served from translation memory
- `cache_status`: `none`, `partial`, or `full`
- `cached_segments`
- `total_segments`
- `translated_text`
- `warnings`
- `elapsed_ms`
- optional `source_text`

Markdown:

- translated Markdown/text only

- [ ] **Step 5: Wire `kotoba translate`**

Use real llama adapter in normal execution, fake only in unit tests.

- [ ] **Step 6: Verify**

```bash
zig build test
```

Manual server-down check:

```bash
zig build run -- translate "Hello" --to ja
```

Expected: fails with `server_unreachable` and startup hints when no server is running.

- [ ] **Step 7: Commit**

```bash
git add src/translate.zig src/output.zig src/input.zig src/main.zig src/cli.zig
git commit -m "feat: wire text translation flow"
```

---

## Task 9: Markdown Protection and Restoration

**Files:**
- Create: `src/markdown.zig`
- Modify: `src/segment.zig`
- Modify: `src/translate.zig`
- Test: `src/markdown.zig`, `src/translate.zig`
- Create: `test/fixtures/markdown_basic.md`
- Create: `test/fixtures/markdown_table.md`

- [ ] **Step 1: Add Markdown fixture tests**

Cover:

- frontmatter preserved
- fenced code block preserved
- inline code preserved
- URL preserved
- link destination preserved while link text is translatable
- image link preserved
- HTML tag preserved
- Markdown table whole block preserved
- headings/paragraphs/list text become translatable segments

- [ ] **Step 2: Implement protection tokens**

Use deterministic tokens such as:

```text
KOTOBA_PROTECT_000001
```

Store mapping in memory and instruct the prompt to preserve tokens exactly.

- [ ] **Step 3: Implement conservative Markdown scanner**

Avoid a full Markdown parser for v1.0.

State-machine scan:

- frontmatter only at file start
- fenced code blocks
- table blocks detected by header line plus separator line
- line-level list markers preserved while item body is segment text
- links split into text and URL protection
- inline code and URLs protected inside translatable text

- [ ] **Step 4: Restore protected tokens after translation**

If a token is missing or altered, return a warning in JSON and keep the best available output. For plain/markdown output, emit warning to stderr.

- [ ] **Step 5: Verify**

```bash
zig build test
```

Expected: all Markdown structure preservation tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/markdown.zig src/segment.zig src/translate.zig test/fixtures
git commit -m "feat: protect Markdown structure during translation"
```

---

## Task 10: File Translation Output Rules

**Files:**
- Modify: `src/input.zig`
- Modify: `src/output.zig`
- Modify: `src/translate.zig`
- Test: `src/output.zig`, `src/translate.zig`

- [ ] **Step 1: Add output path tests**

Cover:

- `README.md --to ja` -> `README.ja.md`
- `README.md --to en` -> `README.en.md`
- `notes.txt --to ja --output notes.ja.txt` writes the requested txt output
- `notes.txt --to ja` defaults to stdout unless `--output` is given
- existing output without `--overwrite` fails with `output_exists`
- `--overwrite` writes
- explicit `--output` path is honored

- [ ] **Step 2: Implement default file output**

For `--file`:

- Markdown file defaults to `markdown` format unless `--format` is explicit.
- Write output file by default for Markdown input.
- Do not overwrite unless `--overwrite`.

For non-Markdown text files:

- Default can remain stdout unless `--output` is given, to avoid surprising file creation.
- If `--output` is given, write the translated txt content there and apply the same no-overwrite rule.
- Do not invent `.ja.txt` / `.en.txt` output files in v1.0 unless the command contract is explicitly changed.

- [ ] **Step 3: Verify**

```bash
zig build test
```

Manual:

```bash
tmpdir=$(mktemp -d)
printf '# Hello\n\nWorld\n' > "$tmpdir/README.md"
zig build run -- translate --file "$tmpdir/README.md" --to ja --no-memory
```

Expected with no server: server error before output file creation.

- [ ] **Step 4: Commit**

```bash
git add src/input.zig src/output.zig src/translate.zig
git commit -m "feat: add file translation output rules"
```

---

## Task 11: Doctor Command

**Files:**
- Create: `src/doctor.zig`
- Modify: `src/main.zig`
- Modify: `src/cli.zig`
- Modify: `src/output.zig`
- Test: `src/doctor.zig`

- [ ] **Step 1: Define check results**

Each check returns:

- name
- status: `ok`, `warn`, `error`
- message
- hints
- error code if applicable

- [ ] **Step 2: Add doctor tests**

Use temp XDG dirs and fake inputs for:

- missing config
- invalid models file
- missing configured model path
- non-loopback `server_url` without explicit remote opt-in
- glossary parse failure
- memory DB open failure
- privacy mode disabled warning

- [ ] **Step 3: Implement checks**

Required:

- config readable
- models readable
- configured model exists
- checksum if configured
- local-only server URL policy
- server health
- memory DB open
- glossary readable
- privacy mode enabled

- [ ] **Step 4: Add JSON doctor output**

Machine-readable shape:

```json
{
  "ok": false,
  "checks": [
    {"name": "server", "status": "error", "code": "server_unreachable", "message": "...", "hints": ["..."]}
  ]
}
```

- [ ] **Step 5: Verify**

```bash
zig build test
zig build run -- doctor
zig build run -- doctor --format json
```

Expected: missing/unreachable pieces are reported clearly without crashing.

- [ ] **Step 6: Commit**

```bash
git add src/doctor.zig src/main.zig src/cli.zig src/output.zig
git commit -m "feat: add doctor diagnostics"
```

---

## Task 12: MVP Management Commands

**Files:**
- Modify: `src/main.zig`
- Modify: `src/cli.zig`
- Modify: `src/config.zig`
- Modify: `src/models.zig`
- Modify: `src/memory.zig`
- Modify: `src/glossary.zig`
- Test: related module tests

- [ ] **Step 1: Implement `config get/set`**

Support at least:

- `server_url`
- `model_id`
- `model_path`
- `memory_enabled`
- `glossary_enabled`
- `default_source_lang`
- `default_target_lang`
- `default_mode`
- `default_output`
- `timeout_sec`
- `privacy_mode`
- `log_level`

- [ ] **Step 2: Implement `models list`**

Print known models with:

- id
- name
- profile
- recommended marker
- configured current marker

- [ ] **Step 3: Implement `memory status/clear`**

`status` should print DB path, enabled flag, row count if readable.

`clear` should ask for `--yes` unless stdin is non-interactive handling is explicitly designed. For automated use, require `memory clear --yes`.

- [ ] **Step 4: Implement `glossary validate`**

Read glossary, print count and parse/hash status.

- [ ] **Step 5: Verify**

```bash
zig build test
```

Manual temp-XDG smoke:

```bash
XDG_CONFIG_HOME=/tmp/kotoba-test-config XDG_DATA_HOME=/tmp/kotoba-test-data zig build run -- config get server_url
XDG_CONFIG_HOME=/tmp/kotoba-test-config XDG_DATA_HOME=/tmp/kotoba-test-data zig build run -- models list
XDG_CONFIG_HOME=/tmp/kotoba-test-config XDG_DATA_HOME=/tmp/kotoba-test-data zig build run -- glossary validate
XDG_CONFIG_HOME=/tmp/kotoba-test-config XDG_DATA_HOME=/tmp/kotoba-test-data zig build run -- memory status
```

- [ ] **Step 6: Commit**

```bash
git add src/main.zig src/cli.zig src/config.zig src/models.zig src/memory.zig src/glossary.zig
git commit -m "feat: add MVP management commands"
```

---

## Task 13: Complete Init Flow

**Files:**
- Modify: `src/main.zig`
- Modify: `src/cli.zig`
- Modify: `src/models.zig`
- Modify: `src/config.zig`
- Modify: `src/memory.zig`
- Modify: `src/llama.zig`
- Modify: `src/translate.zig`
- Test: `src/models.zig`, `src/translate.zig`

- [ ] **Step 1: Define init completion contract**

`kotoba init` is complete only when it can:

- create all XDG directories
- create `models.toml` if missing
- show/select a recommended model only when a verified downloadable entry exists in `models.toml`
- accept `--model-id` / `--model-path` / `--yes` for non-interactive mode
- download a model when `download_url` is set and `--skip-download` is not set
- verify SHA-256 hex checksum when `checksum` is set
- write `config.toml`
- initialize `memory.sqlite3`
- create `glossary.toml` if missing
- run server health check
- run a small test translation only when health check succeeds

- [ ] **Step 2: Add model download/checksum tests without external network**

Use local fixture files under `/tmp` or `test/fixtures`:

- `file://` or direct local copy source succeeds
- configured SHA-256 matches
- configured SHA-256 mismatch returns `checksum_failed`
- `--skip-download` does not fetch and allows later manual model setup

Do not require real internet access in tests.

- [ ] **Step 3: Define supported model acquisition schemes**

v1.0 should support:

- `file://...` copy from a local path
- plain local filesystem paths in `download_url` as a copy source
- `https://...` download for user-provided `models.toml` entries only

Rules:

- `http://...` model downloads are rejected unless a future insecure opt-in is added.
- HTTPS model downloads happen only during `kotoba init` when `--skip-download` is not set.
- HTTPS downloads must use certificate validation through Zig stdlib support; if TLS verification cannot be performed, fail clearly and never fall back to plain HTTP.
- Translation commands must never download models.
- Tests must not depend on public network access; HTTPS behavior can be covered by request-construction/unit boundaries or the local fake server if needed.

- [ ] **Step 4: Implement download boundary**

Keep model acquisition isolated in `src/models.zig`.

Rules:

- Downloads are allowed only from `kotoba init` or future explicit model update commands.
- Translation commands never download models.
- Empty `download_url` means the model must be supplied by `--model-path` or later config.
- Empty `checksum` means checksum verification is skipped with a warning.

- [ ] **Step 5: Implement interactive fallback carefully**

For v1.0, if stdin is non-interactive and required choices are missing, fail with `invalid_arguments` and explain the required flags.

Interactive mode should present:

1. recommended default model only when a verified downloadable entry exists in `models.toml`
2. custom local model path
3. configure later

Avoid blocking automated tests by always supporting `--yes`.

- [ ] **Step 6: Wire memory initialization and server test**

After Task 7 exists, init should create/open the SQLite DB.

Server behavior:

- If server is unreachable, init still writes config and exits with a warning unless the user requested a future strict mode.
- If server is reachable, run a tiny test translation through the normal translation path.
- If `server_url` is non-local, apply the same local-only policy unless `--allow-remote-server` is set.

- [ ] **Step 7: Verify**

```bash
zig build test
tmpdir=$(mktemp -d)
touch "$tmpdir/model.gguf"
XDG_CONFIG_HOME="$tmpdir/config" XDG_DATA_HOME="$tmpdir/data" zig build run -- init --server-url http://127.0.0.1:8080 --model-id custom --model-path "$tmpdir/model.gguf" --skip-download --yes
```

Expected: config, models, glossary, and memory DB are created; the provided model path exists; unreachable server is reported as a warning with startup hints.

- [ ] **Step 8: Commit**

```bash
git add src/main.zig src/cli.zig src/models.zig src/config.zig src/memory.zig src/llama.zig src/translate.zig
git commit -m "feat: complete init flow"
```

---

## Task 14: Integration Smoke Tests

**Files:**
- Create: `test/integration/fake_llama_server.py` or `test/integration/fake_llama_server.zig`
- Create: `test/integration/smoke.sh`
- Modify: `README.md`

- [ ] **Step 1: Add fake llama server**

The fake server should provide:

- `GET /health` returning 200
- `POST /v1/chat/completions` returning a deterministic translation response

Keep it test-only. Python is acceptable for the smoke harness if already available, but do not make it part of the runtime.

- [ ] **Step 2: Add smoke script**

Test:

- temp XDG init
- init creates memory DB
- init reports server warning when server is absent
- direct translation
- JSON output excludes `source_text`
- JSON output includes `source_text` with `--include-source`
- JSON output reports `cache_status`
- Markdown table remains unchanged
- memory hit on second request
- doctor reports server ok

- [ ] **Step 3: Run smoke**

```bash
zig build test
bash test/integration/smoke.sh
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add test/integration README.md
git commit -m "test: add local translation smoke coverage"
```

---

## Task 15: Documentation and Release Readiness

**Files:**
- Modify: `README.md`
- Create: `docs/design-v1.md`
- Create: `docs/privacy.md`
- Create: `docs/llama-server.md`

- [ ] **Step 1: Move the v1.0 design into docs**

Create a concise design document based on the provided specification, keeping:

- goals
- non-goals
- command contract
- data locations
- privacy behavior
- Markdown limitations

- [ ] **Step 2: Document llama.cpp server setup**

Include:

```bash
llama-server -m /path/to/model.gguf --host 127.0.0.1 --port 8080
```

Mention that Kotoba does not auto-start the server in v1.0.

- [ ] **Step 3: Document privacy expectations**

Explicitly state:

- no cloud APIs
- translation command talks only to the configured local loopback server endpoint by default
- source text is not included in JSON unless `--include-source`
- logs do not persist source/translation bodies by default
- SQLite memory stores source and translation text unless disabled

- [ ] **Step 4: Final verification**

```bash
zig fmt build.zig src/*.zig
zig build test
bash test/integration/smoke.sh
```

- [ ] **Step 5: Commit**

```bash
git add README.md docs
git commit -m "docs: document Kotoba CLI v1"
```

---

## Implementation Order Summary

1. Bootstrap Zig project.
2. Build parser and stable error model.
3. Add XDG config and controlled TOML.
4. Add model/glossary/init scaffolding.
5. Add language detection, prompt building, and segmentation.
6. Add llama server adapter.
7. Add SQLite translation memory.
8. Wire translation orchestration and output.
9. Add Markdown protection.
10. Add file output rules.
11. Add doctor.
12. Add small management commands.
13. Complete the full init flow.
14. Add local fake-server smoke tests.
15. Add docs and final verification.

## Key Risks and Mitigations

- **Zig std HTTP instability across versions:** Keep llama adapter small and isolate all HTTP code in `src/llama.zig`.
- **TOML parser scope creep:** Support only project-owned config shapes and fail clearly on unsupported syntax.
- **Markdown corruption:** Prefer conservative protection and whole-table preservation over aggressive translation.
- **SQLite portability:** Use system SQLite first; revisit vendoring only if release packaging requires it.
- **Privacy surprises:** Make `--no-memory` prominent and keep JSON source text opt-in.
- **Server API variance:** Start with OpenAI-compatible llama.cpp endpoint and make adapter boundary explicit for future Ollama/runtime additions.

## Completion Criteria

- `zig build test` passes.
- Local fake-server smoke test passes.
- `kotoba translate "Hello" --to ja` shows a clear server startup hint when no server is running.
- With fake server, direct, stdin, txt file, and Markdown file translation flows work.
- `kotoba init --yes --skip-download --model-id custom --model-path <existing path>` creates config, models, glossary, and memory DB in temp XDG directories.
- Init supports model download and SHA-256 checksum verification without making translation-time network access possible.
- Translation rejects non-loopback `server_url` by default and reports `server_not_local`.
- Markdown tables, code blocks, URLs, link destinations, image links, frontmatter, and HTML tags are preserved.
- JSON output omits `source_text` unless `--include-source`.
- JSON output reports `cache_status`, `cached_segments`, and `total_segments`.
- Translation memory can be enabled, disabled persistently, and disabled per command.
- `kotoba doctor` reports config, models, model path, server, memory, glossary, and privacy status.
