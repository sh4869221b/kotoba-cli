# PROJECT KNOWLEDGE BASE

**Generated:** 2026-08-28 23:17:20 JST
**Commit:** 0e39985 (working tree)
**Branch:** master

## OVERVIEW
Kotoba CLI is a Zig local-first translation CLI. It embeds pinned llama.cpp, runs against local GGUF models, stores config/model registry/glossary/memory under XDG paths, and keeps normal translation network-free.

## STRUCTURE
```text
kotoba-cli/
|-- build.zig              # Zig build, embedded llama.cpp CMake/link contract
|-- src/                   # Zig application modules
|   |-- cli/               # command argument adapters
|   `-- models/            # model registry, download, checksum, validation
|-- test/ci/linux.sh       # canonical format/build/unit/integration stages
|-- test/integration/      # isolated CLI matrix, smoke, benchmark, CUDA QA
|-- .github/               # Ubuntu CPU workflow and verified Zig setup
|-- docs/                  # product contracts and embedded runtime docs
`-- vendor/llama.cpp/      # pinned upstream submodule, own AGENTS.md applies
```

Build/runtime state: `.zig-cache/` (including `llama.cpp/cpu` and `llama.cpp/cuda`, or the same paths under `--cache-dir`), `zig-out/`, and `.omo/`. `.codex/lsp-client.json` is project configuration, not disposable build output. Old `vendor/llama.cpp/build-kotoba*` caches are unused and not automatically removed.

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Build/link changes | `build.zig`, `docs/embedded-llama-api.md` | Keep llama.cpp commit/API/link flags aligned. |
| Command surface | `src/cli.zig`, `src/cli/` | Dispatch, argv validation, command orchestration. |
| Translation behavior | `src/translate.zig`, `src/backend.zig`, `src/llama.zig` | Preserve quiet stdout and embedded runtime. |
| Config/XDG | `src/config.zig`, `src/xdg.zig`, `src/config_tests.zig` | Removed server keys must stay rejected. |
| Model management | `src/models.zig`, `src/models/`, `src/cli/models_cmd.zig` | Downloads happen only through explicit model commands. |
| Model URL safety | `src/url.zig`, `src/net.zig`, `src/models/registry.zig` | Separate request URLs from safe persisted metadata. |
| Privacy/docs | `README.md`, `docs/privacy.md`, `docs/design-v1.md` | Update when behavior changes. |
| CI and build contracts | `test/ci/linux.sh`, `.github/workflows/linux-cpu.yml`, `docs/ci.md` | Four native Linux CPU stages. |
| End-to-end checks | `test/integration/AGENTS.md`, `docs/test-harness.md` | Snapshot binaries, isolated fixtures, CLI receipts. |

## CODE MAP
Locations checked with ZLS and source. The available code graph did not expose
Zig call edges; workspace-wide reference centrality is unmeasured.

| Symbol | Type | Location | Role |
| --- | --- | --- | --- |
| `main` | function | `src/main.zig` | Converts `cli.run` errors to human/JSON output. |
| `cli.run` | function | `src/cli.zig` | Top-level command dispatch. |
| `translate_cmd.run` | function | `src/cli/translate_cmd.zig` | Parses translate flags, writes output. |
| `translate.run/translateSegments` | functions | `src/translate.zig` | Input, Markdown protection, cache lookup, lazy backend session. |
| `backend.init` | function | `src/backend.zig` | Selects the build-time session implementation. |
| `llama.Session` | type | `src/llama.zig` | Owns llama.cpp model/context/sampler lifecycle. |
| `Request/Result` | types | `src/translation_contract.zig` | Shared production/test backend ownership contract. |
| `config.parse/save/setValue` | functions | `src/config.zig` | Config contract and rejected-key behavior. |
| `models.*` | facade | `src/models.zig` | Registry, HF/direct URL, checksum, local install API. |
| `doctor.run` | function | `src/doctor.zig` | Non-mutating diagnostics. |

## CONVENTIONS
- Zig 0.16-style APIs are used: `std.Io`, `std.array_list.Managed`, explicit allocator passing, and inline module tests.
- `src/main.zig` imports modules in its root test with `std.testing.refAllDecls`; new modules must be referenced there.
- Plain and Markdown translation stdout is only translated text. Runtime debug logs require `--debug` or `log_level = "debug"`; ordinary human-readable errors still go to stderr.
- `zig build` is CPU-only. CUDA requires explicit `zig build -Dcuda=true`; `-Dcuda-lib-dir` must be absolute.
- The deterministic backend is build-time only through `-Dtest-backend=true`; do not add runtime fake-mode environment switches.
- Network access is allowed for explicit `kotoba models pull` flows only, never for normal `translate`.

## ANTI-PATTERNS (THIS PROJECT)
- Do not reintroduce removed external server config keys: `runtime`, `server_url`, `server_autostart`, `llama_server_path`, `server_startup_timeout_sec`.
- Do not make translation contact cloud APIs or remote endpoints.
- Do not persist source or translated bodies in logs/debug output; SQLite memory is the explicit storage path.
- Do not make default tests depend on real internet, a real model, CUDA hardware, or an installed `curl`; explicit CUDA QA is separate.
- Do not edit generated build output or vendor upstream code unless the task is explicitly about that boundary.
- Do not add backwards-compat aliases such as `gpu_layers = "auto"` or `"all"`; `gpu_layers` is signed integer only.

## COMMANDS
The Zig compiler is pinned in `mise.toml`. Run Zig commands and integration
scripts through `mise exec --` (for example, `mise exec -- zig build test`) so
non-interactive Codex shells use the project toolchain without global activation.
ZLS is not managed by mise; install ZLS 0.16.0 globally on PATH.
For Zig language-server operations, use the OMO built-in ZLS, enabled in
`.codex/lsp-client.json`. Use `mise exec -- zig ast-check <file>` for standalone
syntax checks and the build/test commands for compilation diagnostics.

```bash
git submodule update --init --recursive
mise exec -- zig fmt --check build.zig src
mise exec -- zig build test
mise exec -- zig build test -Dtest-backend=true
mise exec -- zig build
mise exec -- bash test/integration/smoke.sh
mise exec -- zig build bench
mise exec -- bash test/ci/linux.sh format # also: build, unit, integration
KOTOBA_CUDA_MODEL=/path/to/model.gguf mise exec -- bash test/integration/cuda_smoke.sh
```

## NOTES
- `build.zig`, the Git submodule index, and `docs/embedded-llama-api.md` must agree on the llama.cpp pin. Keep the initialized submodule's Git metadata; a source-only directory fails the build guard.
- Native Linux links both CLI and tests with LLVM + bundled LLD to handle system CRT `.sframe` relocations. Required CI is Ubuntu 24.04 x86_64 CPU; macOS is unverified, cross-compilation and Windows are unsupported.
- `src/llama_api_probe.c` is compiled with `-fsyntax-only` during build to catch llama.cpp C API drift early.
- Markdown tables are intentionally left untranslated in v1 to preserve structure.
- `docs/superpowers/plans/` contains historical plans; use current docs/source/tests as truth when they diverge.
