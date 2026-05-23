# Embedded llama.cpp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `kotoba` run translation through an in-process llama.cpp runtime and add first-class model management commands.

**Architecture:** Replace the current OpenAI-compatible HTTP client/runtime path with a direct `libllama` backend loaded from a pinned llama.cpp submodule. Keep local-first behavior by requiring a local GGUF model path and removing `server_url`, remote server opt-in, `llama-server` autostart, and API compatibility paths instead of preserving them.

**Tech Stack:** Zig CLI, pinned llama.cpp submodule built as static `libllama`/ggml libraries, llama.cpp C API (`include/llama.h`), GGUF model files, existing XDG config/data/cache layout, SQLite translation memory, shell smoke tests.

---

## Decision Record

- Do not keep API/server backward compatibility. Delete the external HTTP adapter, remote endpoint option, and command-scoped `llama-server` process manager once the embedded backend is ready.
- Use llama.cpp as a pinned Git submodule, not as committed source files or an installed `llama-server` binary on `PATH`.
- Build CPU-only first with `BUILD_SHARED_LIBS=OFF`. GPU backends can be added later behind explicit build options after the embedded CPU path is stable.
- Keep model files outside the executable. "Embedded llama.cpp" means the inference engine is built into `kotoba`; GGUF models remain user-managed assets under XDG data/config paths.
- Add model management under `kotoba models ...`; `kotoba init` should become a thin setup path that selects or imports a model through the same model registry logic.
- Use one canonical "no selected model" state: `model_id = ""` and `model_path = ""`. `translate` fails with `model_not_selected`, `doctor` reports `selected_model` as an error, and `models verify` without an ID fails with `model_not_selected`.
- Add a compile-time test backend option for deterministic smoke tests. It must never be enabled in normal release builds.

## External Grounding

- Official llama.cpp build docs describe the `llama` library as the main product and point to `include/llama.h` as the C-style interface.
- Official build docs support CPU builds with CMake and static builds with `-DBUILD_SHARED_LIBS=OFF`.
- Official README documents `llama-server` as a separate OpenAI-compatible HTTP server, which this plan intentionally removes from Kotoba's runtime.

## Current State

- `build.zig` builds one executable and one test binary from `src/main.zig`, links libc, and links only system `sqlite3`.
- `src/llama.zig` is an HTTP client for `/health` and `/v1/chat/completions`.
- `src/runtime.zig` resolves and starts external `llama-server` processes.
- `src/translate.zig` calls `runtime.ensureServer` before the first uncached segment, then calls `llama.translateSegment`.
- `src/config.zig` persists server-specific keys: `runtime`, `server_url`, `server_autostart`, `llama_server_path`, and `server_startup_timeout_sec`.
- `src/doctor.zig`, `README.md`, `docs/llama-server.md`, `docs/design-v1.md`, and `docs/privacy.md` all describe external server behavior.
- `src/models.zig` can parse `models.toml`, copy/download model files, and verify SHA-256, but CLI support is limited to `kotoba models list`.

## Target Command Contract

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

Removed user-facing contract:

```text
--server-url
--allow-remote-server
runtime
server_url
server_autostart
llama_server_path
server_startup_timeout_sec
```

## File Structure

- Create `vendor/llama.cpp/` as a Git submodule.
  - Pin a specific upstream revision through the submodule gitlink.
  - Exclude model files and build output from version control.
- Modify `build.zig`
  - Add a `llama-cpp` build step that configures the submodule tree with CMake.
  - Link the resulting static llama.cpp/ggml libraries into both `kotoba` and tests.
  - Add include paths for `vendor/llama.cpp/include`, `vendor/llama.cpp/ggml/include`, and any generated build include directory required by the pinned revision.
  - Add a `-Dtest-backend=true` build option that compiles a deterministic fake embedded backend for integration smoke tests only.
- Modify `build.zig.zon`
  - Keep package metadata accurate. Add no runtime package dependency unless Zig package management is chosen for the upstream source.
- Delete `src/runtime.zig`
  - Remove external process management, locks, signal handling, executable resolution, and health polling.
- Replace `src/llama.zig`
  - Convert it from HTTP client to embedded C API wrapper.
  - Own llama.cpp backend init/free, model load/free, context creation/free, prompt evaluation, token sampling, timeout/cancel checks, and generated text ownership.
- Create `src/backend.zig`
  - Define a small translation backend interface used by `src/translate.zig`.
  - This should have only the embedded implementation after migration, not a server fallback.
- Modify `src/translate.zig`
  - Remove `runtime.ensureServer`.
  - Load/reuse one embedded session per command before the first uncached segment.
  - Preserve translation memory and Markdown protection behavior.
- Modify `src/config.zig`
  - Remove server fields.
  - Add embedded runtime settings:
    - `model_id: []const u8`
    - `model_path: []const u8`
    - `context_length: u32 = 4096`
    - `threads: u32 = 0`
    - `max_tokens: u32 = 1024`
    - `temperature: f32 = 0.2`
    - `timeout_sec: u32 = 120`
  - Parse/save/set/get only supported keys.
- Modify `src/models.zig`
  - Add registry write/update/remove support.
  - Add model installation path helpers under XDG data, for example `${XDG_DATA_HOME}/kotoba/models/<id>.gguf`.
  - Add llama.cpp-style Hugging Face and direct HTTPS model download helpers for `models pull`.
  - Add ID validation and duplicate protection.
- Modify `src/cli.zig`
  - Remove server flags from `init` and `translate`.
  - Add `config list` so users can discover supported configurable keys.
  - Add `models info/import/pull/use/verify/remove`.
  - Reuse `models.acquire`/checksum code instead of duplicating file operations.
- Modify `src/doctor.zig`
  - Report embedded engine readiness, model registry health, configured model existence, checksum status, memory, glossary, and privacy.
  - Do not create, download, or mutate models.
- Modify `src/errors.zig`
  - Remove server-specific error messages.
  - Add embedded runtime errors such as `model_missing`, `model_load_failed`, `llama_init_failed`, `llama_decode_failed`, `model_not_selected`, and `model_registry_invalid`.
- Modify `src/main.zig`
  - Remove `runtime` from test declarations and include any new modules.
- Modify docs:
  - `README.md`
  - Replace `docs/llama-server.md` with `docs/embedded-llama.md`, or rewrite it with the new title.
  - `docs/design-v1.md`
  - `docs/privacy.md`
- Modify tests:
  - Delete server/autostart-only smoke assertions.
  - Add a deterministic embedded backend test seam for CLI smoke without requiring a real large model.
  - Keep model import/verify/remove smoke tests using tiny local files and checksum validation.

## Task 1: Vendor And Build Contract

**Files:**
- Create: `vendor/llama.cpp/` submodule gitlink
- Modify: `build.zig`
- Modify: `build.zig.zon`
- Modify: `.gitignore` if build artifacts need ignoring
- Test: build graph only

- [ ] **Step 1: Pin the llama.cpp submodule**

Choose a specific upstream commit from `ggml-org/llama.cpp` and record it through `.gitmodules` plus the submodule gitlink:

```text
vendor/llama.cpp upstream: ggml-org/llama.cpp <commit>
reason: first embedded CPU-only integration
```

Do not commit the upstream source files into the Kotoba repository.

- [ ] **Step 2: Record the exact C API contract for the pinned revision**

Before writing the Zig wrapper, inspect the pinned headers and record the exact symbols and ownership rules used by this project in `docs/embedded-llama-api.md`:

```text
llama_backend_init
llama_model_default_params
llama_model_load_from_file
llama_context_default_params
llama_init_from_model
llama_tokenize
llama_decode
llama_sampler_* functions selected for v1
llama_model_free
llama_free
llama_backend_free
```

If any symbol name differs in the pinned revision, update this plan's implementation steps before coding. The wrapper must follow the pinned header, not memory or examples from another revision.

- [ ] **Step 3: Add a C API compile probe**

Add a tiny build-time C or Zig compile probe that includes `llama.h` and references the exact symbols from `docs/embedded-llama-api.md`. Wire it into the `llama-cpp` build step so API drift fails before wrapper implementation.

- [ ] **Step 4: Add build artifact ignores**

Ensure generated CMake output is ignored, for example:

```gitignore
vendor/llama.cpp/build-kotoba/
```

- [ ] **Step 5: Add a CMake configure/build step**

In `build.zig`, add a helper that runs CMake for the pinned source:

```text
cmake -S vendor/llama.cpp -B vendor/llama.cpp/build-kotoba -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF
cmake --build vendor/llama.cpp/build-kotoba --config Release
```

The first implementation may keep CPU defaults only. Do not enable CUDA, Metal, Vulkan, HIP, or BLAS in this task.

- [ ] **Step 6: Link embedded libraries into executable and tests**

Update both the executable and test build modules to:

- add llama.cpp include directories
- link C++
- link the static llama.cpp/ggml libraries produced by the pinned build
- keep `sqlite3` linking unchanged

If the pinned CMake output names differ, inspect the generated static libraries once and codify the exact list in `build.zig`.

- [ ] **Step 7: Add deterministic test backend build option**

Add:

```text
zig build -Dtest-backend=true
```

When enabled, `kotoba` links a deterministic fake embedded backend that returns `JA:` plus the text extracted from the prompt. The option must be false by default and must be used only by smoke tests.

- [ ] **Step 8: Verify**

Run:

```bash
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build -Dtest-backend=true
```

Expected: build reaches link stage with llama.cpp libraries found. If `src/llama.zig` still references HTTP code, link/runtime behavior is not expected to be complete yet.

- [ ] **Step 9: Commit**

```bash
git add build.zig build.zig.zon .gitignore vendor/llama.cpp docs/embedded-llama-api.md
git commit -m "build: vendor llama.cpp for embedded runtime"
```

## Task 2: Config Migration Without Server Compatibility

**Files:**
- Modify: `src/config.zig`
- Modify: `src/cli.zig`
- Modify: `src/errors.zig`
- Test: `src/config.zig`, CLI config smoke

- [ ] **Step 1: Write failing config tests**

Add tests that parse and round-trip:

```toml
model_id = "local-ja"
model_path = "/tmp/local-ja.gguf"
context_length = 4096
threads = 0
max_tokens = 1024
temperature = 0.2
timeout_sec = 120
```

Add tests proving removed keys are not accepted by `config set`:

```text
runtime
server_url
server_autostart
llama_server_path
server_startup_timeout_sec
```

Expected: tests fail until server keys are removed and embedded keys are implemented.

- [ ] **Step 2: Remove server config fields**

Delete these fields from `Config`, parsing, saving, `setValue`, and `printConfigValue`:

```zig
runtime
server_url
server_autostart
llama_server_path
server_startup_timeout_sec
```

Do not keep aliases or migration shims for old config keys.

- [ ] **Step 3: Add embedded config fields**

Add:

```zig
context_length: u32 = 4096,
threads: u32 = 0,
max_tokens: u32 = 1024,
temperature: f32 = 0.2,
timeout_sec: u32 = 120,
```

Keep `model_id` and `model_path` as the selected model identity/path.

The no-selected-model state is:

```toml
model_id = ""
model_path = ""
```

This state is valid for `init`, `config`, `models`, and `doctor`, but `translate` must return `model_not_selected`.

- [ ] **Step 4: Update CLI config get/set/list**

Supported configurable keys after this task:

```text
default_source_lang
default_target_lang
default_mode
default_output
model_id
model_path
context_length
threads
max_tokens
temperature
timeout_sec
memory_enabled
glossary_enabled
privacy_mode
log_level
```

Attempting to set removed server keys must return `invalid_arguments`.

- [ ] **Step 5: Add `config list`**

Add:

```bash
kotoba config list
```

Expected output should be stable, one key per line, and limited to keys accepted by `kotoba config set`:

```text
default_source_lang
default_target_lang
default_mode
default_output
model_id
model_path
context_length
threads
max_tokens
temperature
timeout_sec
memory_enabled
glossary_enabled
privacy_mode
log_level
```

Do not include removed server keys such as `server_url`, `runtime`, `server_autostart`, `llama_server_path`, or `server_startup_timeout_sec`.

- [ ] **Step 6: Add config list tests**

Add a unit or smoke assertion that:

- `kotoba config list` succeeds after init
- every listed key is accepted by `kotoba config set` with a valid sample value
- removed server keys are absent from the list

- [ ] **Step 7: Verify**

Run:

```bash
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build test
```

Expected: config tests pass and no code references deleted config fields.

- [ ] **Step 8: Commit**

```bash
git add src/config.zig src/cli.zig src/errors.zig
git commit -m "refactor: replace server config with embedded runtime settings"
```

## Task 3: Embedded Backend Interface

**Files:**
- Create: `src/backend.zig`
- Modify: `src/translate.zig`
- Modify: `src/main.zig`
- Test: `src/backend.zig`, `src/translate.zig`

- [ ] **Step 1: Add a test backend**

Create a small backend contract that can be unit-tested without llama.cpp:

```zig
pub const Request = struct {
    model_id: []const u8,
    prompt: []const u8,
    timeout_sec: u32,
};

pub const VTable = struct {
    translate: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, req: Request) anyerror![]const u8,
    deinit: *const fn (ctx: *anyopaque) void,
};
```

Add a fake implementation returning `JA:` plus the source text parsed from the prompt.

- [ ] **Step 2: Wire the build-time test backend into CLI smoke**

When `-Dtest-backend=true` is set, `backend.zig` must expose the fake implementation as the default backend used by `translate.run`. Normal builds must use the llama.cpp implementation only.

The smoke script must build and call the test binary explicitly:

```bash
zig build -Dtest-backend=true
KOTOBA_BIN="${PWD}/zig-out/bin/kotoba" bash test/integration/smoke.sh
```

Do not use an environment variable to switch production binaries into fake mode. `KOTOBA_BIN` only selects the already-built executable path for the smoke script; the fake behavior must come solely from the `-Dtest-backend=true` compile-time option.

- [ ] **Step 3: Refactor `translate.run` to use the backend**

Change `translate.run` so it receives or creates a backend session once per command and calls it for uncached segments.

Required behavior:

- Cache hits do not call the backend.
- One backend session is reused for all uncached segments in the command.
- Markdown protection, glossary, JSON output, and memory keys remain unchanged.

- [ ] **Step 4: Remove runtime startup dependency**

Delete the import and call to `runtime.ensureServer` from `src/translate.zig`.

- [ ] **Step 5: Define missing model behavior**

Before backend initialization, if `cfg.model_id.len == 0` or `cfg.model_path.len == 0`, return `model_not_selected`.

- [ ] **Step 6: Verify**

Run:

```bash
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build test
```

Expected: translation tests pass through the fake backend.

- [ ] **Step 7: Commit**

```bash
git add src/backend.zig src/translate.zig src/main.zig
git commit -m "refactor: route translation through embedded backend interface"
```

## Task 4: llama.cpp C API Wrapper

**Files:**
- Replace: `src/llama.zig`
- Modify: `src/backend.zig`
- Modify: `src/errors.zig`
- Test: `src/llama.zig`

- [ ] **Step 1: Replace HTTP types with embedded types**

Delete HTTP URL parsing, socket code, `/health`, request serialization, and response parsing from `src/llama.zig`.

Add types:

```zig
pub const Options = struct {
    model_path: []const u8,
    model_id: []const u8,
    context_length: u32,
    threads: u32,
    max_tokens: u32,
    temperature: f32,
    timeout_sec: u32,
};

pub const Session = struct {
    pub fn init(allocator: std.mem.Allocator, opts: Options) !Session;
    pub fn translate(self: *Session, allocator: std.mem.Allocator, prompt: []const u8) ![]const u8;
    pub fn deinit(self: *Session) void;
};
```

- [ ] **Step 2: Import llama.cpp headers from the pinned API contract**

Use `@cImport` with the submodule headers:

```zig
const c = @cImport({
    @cInclude("llama.h");
});
```

Cross-check every symbol against `docs/embedded-llama-api.md` before coding. If the pinned header differs from the function names below, update this task and the compile probe first.

- [ ] **Step 3: Implement backend lifecycle**

`Session.init` must:

- call llama.cpp backend initialization once per process
- validate `model_path` exists
- load the model with the pinned model-load function
- create a context with the pinned context-init function
- return `model_load_failed` or `llama_init_failed` on failure

`Session.deinit` must free context/model resources in reverse order.

- [ ] **Step 4: Implement single-prompt generation using pinned sampler APIs**

`Session.translate` must:

- tokenize the full prompt
- decode prompt tokens
- sample up to `max_tokens`
- stop on EOS or timeout
- return generated UTF-8 text owned by the caller

Keep sampling minimal for v1: temperature plus llama.cpp defaults are enough.

Do not proceed until the compile probe and `docs/embedded-llama-api.md` agree with the wrapper implementation.

- [ ] **Step 5: Add unit-level coverage for error mapping**

Use missing model paths and invalid options to test:

```text
model_missing
model_load_failed
llama_init_failed
```

Do not require a real model in unit tests.

- [ ] **Step 6: Verify**

Run:

```bash
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build test
```

Expected: unit tests pass without a real GGUF model.

- [ ] **Step 7: Commit**

```bash
git add src/llama.zig src/backend.zig src/errors.zig
git commit -m "feat: add embedded llama.cpp backend"
```

## Task 5: Remove Server Runtime And API Flags

**Files:**
- Delete: `src/runtime.zig`
- Modify: `src/main.zig`
- Modify: `src/cli.zig`
- Modify: `src/errors.zig`
- Modify: `test/integration/smoke.sh`
- Delete or repurpose: `test/integration/fake_llama_server.py`

- [ ] **Step 1: Delete server runtime module**

Remove `src/runtime.zig` and all imports.

- [ ] **Step 2: Remove API flags**

Delete support for:

```text
kotoba init --server-url
kotoba translate --allow-remote-server
```

These must fail with `invalid_arguments`; do not silently ignore them.

- [ ] **Step 3: Add negative CLI tests for removed API flags**

Add smoke assertions that these commands fail with `invalid_arguments`:

```bash
kotoba init --server-url http://127.0.0.1:8080 --yes
kotoba translate "Hello" --to ja --allow-remote-server
```

These tests must run after `init` creates config, so they prove the parser rejects the removed flags rather than failing because the repo is uninitialized.

- [ ] **Step 4: Remove server errors**

Delete or stop emitting:

```text
server_unreachable
server_start_failed
server_startup_timeout
server_autostart_disabled
server_user_managed_endpoint
server_bad_response
server_not_local
```

Replace with embedded errors where needed.

- [ ] **Step 5: Clean smoke tests**

Remove fake server startup, remote rejection, autostart, base-path, timeout, and child cleanup assertions.

Keep smoke coverage for:

- init with a local model path
- translation using the `-Dtest-backend=true` build
- Markdown protection
- JSON output
- memory cache hit without backend invocation
- model management commands from Task 6

- [ ] **Step 6: Verify**

Run:

```bash
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build test
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build -Dtest-backend=true
KOTOBA_BIN="${PWD}/zig-out/bin/kotoba" bash test/integration/smoke.sh
```

Expected: no code path or smoke output mentions `llama-server`, `server_url`, or remote API connection. Smoke runs against a binary built with `-Dtest-backend=true`.

- [ ] **Step 7: Commit**

```bash
git add -A src test/integration
git commit -m "refactor: remove llama-server API runtime"
```

## Task 6: Model Management Commands

**Files:**
- Modify: `src/models.zig`
- Modify: `src/cli.zig`
- Modify: `src/config.zig`
- Modify: `src/xdg.zig`
- Modify: `test/integration/smoke.sh`
- Test: `src/models.zig`

- [ ] **Step 1: Add model storage path**

Extend `xdg.Paths` with:

```zig
models_dir: []const u8,
```

Set it to:

```text
${XDG_DATA_HOME}/kotoba/models
```

Ensure `xdg.ensureDirs` creates it.

- [ ] **Step 2: Add registry mutation helpers**

In `src/models.zig`, add helpers:

```zig
pub fn validateId(id: []const u8) !void;
pub fn installPath(allocator: std.mem.Allocator, paths: xdg.Paths, id: []const u8) ![]const u8;
pub fn addOrUpdate(path: []const u8, model: Model) !void;
pub fn remove(path: []const u8, id: []const u8) !void;
pub fn verifySelected(allocator: std.mem.Allocator, cfg: config.Config, list: List) !void;
```

ID validation should allow ASCII letters, digits, `_`, `-`, and `.` only.

- [ ] **Step 3: Implement `models info ID`**

Print:

```text
id:
name:
profile:
path:
format:
quantization:
context_length:
checksum:
license:
notes:
current: true|false
installed: true|false
```

Return `invalid_arguments` for unknown IDs.

- [ ] **Step 4: Implement `models import`**

Command:

```bash
kotoba models import --id local-ja --path /path/model.gguf --name "Local JA" --checksum SHA256 --use
```

Behavior:

- copy the file to `${XDG_DATA_HOME}/kotoba/models/local-ja.gguf`
- verify checksum when provided
- update `models.toml`
- set `config.model_id` and `config.model_path` when `--use` is passed

- [ ] **Step 5: Implement registry-based `models pull ID`**

Behavior:

- find ID in `models.toml`
- require `https://` or `file://` download source
- reject `http://`
- install to `models_dir` unless `--output PATH` is supplied
- verify checksum when present
- set config when `--use` is passed

Reuse `models.acquire`.

- [ ] **Step 6: Implement llama.cpp-style Hugging Face model pull**

Match the useful local-download behavior of `llama-server -hf` without reintroducing the HTTP inference server:

```bash
kotoba models pull --hf-repo ggml-org/GLM-4.7-Flash-GGUF:Q4_K_M --use
kotoba models pull --hf-repo ggml-org/GLM-4.7-Flash-GGUF --hf-file GLM-4.7-Flash-Q4_K_M.gguf --id glm-4.7-flash-q4 --use
```

Behavior:

- accept `--hf-repo USER/MODEL[:QUANT]`
- default `QUANT` to `Q4_K_M`
- accept `--hf-file FILE`; when supplied, it overrides the quant-derived file selection
- reject `--hf-file` values that do not end in `.gguf`
- resolve only `.gguf` files for v1
- if quant is supplied and no exact matching GGUF exists, fall back to the first GGUF file in repository listing order and print a warning
- support private/gated repositories with `HF_TOKEN`; do not persist tokens in config, models.toml, logs, or errors
- install to `models_dir` unless `--output PATH` is supplied
- choose a stable default ID from repo/model/quant unless `--id ID` is supplied
- if the target ID already exists, fail with `invalid_arguments` unless a future explicit `--replace` flag is added; do not overwrite registry entries implicitly
- write a registry entry with source metadata, resolved file name, installed path, and checksum/etag metadata when available
- set `config.model_id` and `config.model_path` when `--use` is passed

Do not support llama.cpp's Docker Hub model source in this task. Keep the first implementation to Hugging Face and direct HTTPS URLs.

- [ ] **Step 7: Implement direct URL model pull**

Match the useful part of `llama-server --model-url`:

```bash
kotoba models pull --model-url https://example.com/model.gguf --id example-q4 --checksum SHA256 --use
```

Behavior:

- require `https://`
- reject `http://`
- require `--id`
- require `--checksum` unless the URL source is already present in `models.toml` with a checksum
- install to `models_dir` unless `--output PATH` is supplied
- write or update a registry entry in `models.toml` with ID, source URL, installed path, and checksum metadata
- set config when `--use` is passed

- [ ] **Step 8: Add model pull resolver tests**

Add unit tests that do not require network access:

- parse `USER/MODEL:Q4_K_M`
- default missing quant to `Q4_K_M`
- `--hf-file` overrides quant selection
- generated default IDs are stable and pass `validateId`
- `http://` direct URLs are rejected
- missing checksum for ad-hoc `--model-url` is rejected
- token-bearing inputs are never rendered in error strings

- [ ] **Step 9: Implement `models use ID`**

Behavior:

- require the model exists in registry
- require an installed local path exists
- set `model_id` and `model_path`
- do not download

- [ ] **Step 10: Implement `models verify [ID]`**

Behavior:

- with ID: verify that one model path exists and checksum matches when present
- without ID: verify selected `config.model_id`
- print `ok` on success

- [ ] **Step 11: Implement `models remove ID --yes`**

Behavior:

- remove the registry entry for ID
- delete the installed model file under `models_dir` if it matches the managed path
- when removing the currently selected model, set the canonical no-selected-model state: `model_id = ""` and `model_path = ""`
- after removal, `translate` must fail with `model_not_selected`, `doctor` must report `selected_model` as an error, and `models verify` without an ID must fail with `model_not_selected`

- [ ] **Step 12: Add smoke coverage**

Use tiny local files:

```bash
printf 'model bytes' > "${TMP}/toy.gguf"
SUM="$(sha256sum "${TMP}/toy.gguf" | awk '{print $1}')"
kotoba models import --id toy --path "${TMP}/toy.gguf" --checksum "$SUM" --use
kotoba models info toy
kotoba models verify toy
kotoba models use toy
kotoba models remove toy --yes
```

Add network-free smoke coverage for the new pull paths using `file://` or a local HTTPS fixture only if one already exists in the repo. Do not make normal smoke depend on Hugging Face availability.

- [ ] **Step 13: Add optional manual Hugging Face verification**

Document, but do not require in CI:

```bash
kotoba models pull --hf-repo ggml-org/GLM-4.7-Flash-GGUF:Q4_K_M --use
kotoba models verify
```

Expected: model downloads into `${XDG_DATA_HOME}/kotoba/models`, registry metadata is written, and `kotoba config get model_path` points at the installed GGUF.

- [ ] **Step 14: Verify**

Run:

```bash
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build test
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build -Dtest-backend=true
KOTOBA_BIN="${PWD}/zig-out/bin/kotoba" bash test/integration/smoke.sh
```

- [ ] **Step 15: Commit**

```bash
git add src/models.zig src/cli.zig src/config.zig src/xdg.zig test/integration/smoke.sh
git commit -m "feat: add model management commands"
```

## Task 7: Init And Doctor On Embedded Runtime

**Files:**
- Modify: `src/cli.zig`
- Modify: `src/doctor.zig`
- Modify: `src/errors.zig`
- Test: `src/cli.zig`, `src/doctor.zig`, smoke

- [ ] **Step 1: Simplify `init`**

New `init` behavior:

- create XDG dirs and default files
- if only `--model-path` is supplied, import/select it through the model registry using `model_id = "custom"` unless `--model-id` is also provided
- if only `--model-id` is supplied, select an installed model from the registry
- if both `--model-id` and `--model-path` are supplied, import/select that path under the supplied ID
- do not contact any server
- do not run a test translation during init

- [ ] **Step 2: Update `doctor` checks**

Checks:

```text
config
llama_cpp
models
selected_model
model_file
model_checksum
memory
glossary
privacy
```

`doctor` must not load a large model by default. It should validate file presence/checksum and report that embedded llama.cpp is linked.

If `model_id = ""` or `model_path = ""`, `doctor` must print/report:

```text
selected_model: error: model_not_selected
```

and continue checking memory, glossary, and privacy.

- [ ] **Step 3: Add JSON output coverage**

Ensure `doctor --format json` returns stable names and codes for embedded checks.

- [ ] **Step 4: Verify**

Run:

```bash
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build test
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build -Dtest-backend=true
KOTOBA_BIN="${PWD}/zig-out/bin/kotoba" bash test/integration/smoke.sh
```

- [ ] **Step 5: Commit**

```bash
git add src/cli.zig src/doctor.zig src/errors.zig test/integration/smoke.sh
git commit -m "refactor: make init and doctor embedded-runtime aware"
```

## Task 8: Documentation And Privacy Update

**Files:**
- Modify: `README.md`
- Delete or replace: `docs/llama-server.md`
- Modify: `docs/design-v1.md`
- Modify: `docs/privacy.md`

- [ ] **Step 1: Update README quickstart**

Document:

```bash
kotoba models import --id local --path /path/to/model.gguf --use
kotoba config list
kotoba translate "Hello world" --to ja
```

Remove all `llama-server`, `server_url`, and remote endpoint instructions.

- [ ] **Step 2: Replace server setup docs**

Either rename `docs/llama-server.md` to `docs/embedded-llama.md` or rewrite the existing file so it explains:

- bundled llama.cpp engine
- GGUF model requirement
- model commands, including llama.cpp-style Hugging Face model download with `models pull --hf-repo`
- `config list` for discovering supported settings
- CPU-only default build
- optional future GPU backend note

- [ ] **Step 3: Update design doc**

Change goals/non-goals and translation flow:

- direct embedded inference
- no cloud API
- no external server runtime
- models stored under XDG data

- [ ] **Step 4: Update privacy doc**

State that normal translation performs no network request. Network access can occur only when the user runs `kotoba models pull` for an HTTPS model source.

Document that Hugging Face downloads use `HF_TOKEN` only when needed and never persist the token.

- [ ] **Step 5: Verify docs**

Search for removed terms:

```bash
rg "llama-server|server_url|allow-remote|remote server|OpenAI-compatible" README.md docs src test
```

Expected: no stale user-facing instructions remain, except historical references in this plan.

- [ ] **Step 6: Commit**

```bash
git add README.md docs
git commit -m "docs: document embedded llama runtime"
```

## Task 9: Full Verification

**Files:**
- No source changes expected unless verification finds defects.

- [ ] **Step 1: Format**

Run:

```bash
zig fmt build.zig src/*.zig
```

- [ ] **Step 2: Unit tests**

Run:

```bash
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build test
```

Expected: all tests pass.

- [ ] **Step 3: Build**

Run:

```bash
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build
```

Expected: `zig-out/bin/kotoba` links embedded llama.cpp.

- [ ] **Step 4: Smoke**

Run:

```bash
env ZIG_GLOBAL_CACHE_DIR=.zig-cache/global zig build -Dtest-backend=true
KOTOBA_BIN="${PWD}/zig-out/bin/kotoba" bash test/integration/smoke.sh
```

Expected: smoke passes without starting `llama-server`.

- [ ] **Step 5: Stale API sweep**

Run:

```bash
rg "runtime|server_url|server_autostart|llama_server_path|server_startup_timeout_sec|allow_remote_server|allow-remote-server|llama-server|server_unreachable|server_start_failed|server_startup_timeout|server_autostart_disabled|server_user_managed_endpoint|server_bad_response|server_not_local|/v1/chat/completions|/health|OpenAI-compatible" .
```

Expected: only this plan or intentionally retained upstream/vendor files match.

- [ ] **Step 6: Commit final fixes if needed**

```bash
git add -A
git commit -m "test: verify embedded llama runtime migration"
```

## Rollout Risks

- llama.cpp C API can drift. Pin the submodule revision and update intentionally.
- Static linking names and generated include paths may differ by llama.cpp revision. Task 1 must codify the exact pinned output.
- Real model integration tests are expensive. Keep unit/smoke tests deterministic, and document one optional manual test using a small GGUF model.
- Removing API compatibility is intentionally breaking. The docs and error messages must be clear that `server_url` and remote endpoints are no longer supported.
- Model downloads can be large. `models pull` must require HTTPS, checksum verification when metadata provides it, and clear progress/error behavior.
- Hugging Face downloads must not persist access tokens. Read tokens from `HF_TOKEN` or an explicit token environment variable only, and redact them from errors/logs.
