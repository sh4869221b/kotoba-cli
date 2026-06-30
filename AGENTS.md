# PROJECT KNOWLEDGE BASE

**Generated:** 2026-06-30 18:34:18 JST
**Commit:** 4a94619
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
|-- test/integration/      # shell smoke, benchmark, guarded CUDA QA
|-- docs/                  # product contracts and embedded runtime docs
`-- vendor/llama.cpp/      # pinned upstream submodule, own AGENTS.md applies
```

Generated or runtime state: `.zig-cache/`, `zig-out/`, `.omo/`, `.codex/`, `.agents/`, and `vendor/llama.cpp/build-kotoba*`.

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Build/link changes | `build.zig`, `docs/embedded-llama-api.md` | Keep llama.cpp commit/API/link flags aligned. |
| Command surface | `src/cli.zig`, `src/cli/` | `cli.run` dispatches; subcommands parse argv only. |
| Translation behavior | `src/translate.zig`, `src/backend.zig`, `src/llama.zig` | Preserve quiet stdout and embedded runtime. |
| Config/XDG | `src/config.zig`, `src/xdg.zig`, `src/config_tests.zig` | Removed server keys must stay rejected. |
| Model management | `src/models.zig`, `src/models/`, `src/cli/models_cmd.zig` | Downloads happen only through explicit model commands. |
| Privacy/docs | `README.md`, `docs/privacy.md`, `docs/design-v1.md` | Update when behavior changes. |
| End-to-end checks | `test/integration/*.sh` | Use test backend for deterministic QA. |

## CODE MAP
| Symbol | Type | Location | Refs | Role |
| --- | --- | --- | --- | --- |
| `main` | function | `src/main.zig` | entry | Converts `cli.run` errors to human/JSON output. |
| `cli.run` | function | `src/cli.zig` | entry | Top-level command dispatch. |
| `translate_cmd.run` | function | `src/cli/translate_cmd.zig` | command | Parses translate flags, writes output. |
| `translate.run` | function | `src/translate.zig` | central | Reads input, protects Markdown, memory lookup, backend session, output result. |
| `backend.init` | function | `src/backend.zig` | central | Chooses deterministic test backend or embedded llama session. |
| `llama.Session` | type | `src/llama.zig` | central | Owns llama.cpp model/context/sampler lifecycle. |
| `config.parse/save/setValue` | functions | `src/config.zig` | central | Config contract and rejected-key behavior. |
| `models.*` | facade | `src/models.zig` | central | Registry, HF/direct URL, checksum, local install API. |
| `doctor.run` | function | `src/doctor.zig` | command | Non-mutating diagnostics. |

## CONVENTIONS
- Zig 0.16-style APIs are used: `std.Io`, `std.array_list.Managed`, explicit allocator passing, and inline module tests.
- `src/main.zig` imports modules in its root test with `std.testing.refAllDecls`; new modules must be referenced there.
- Plain and Markdown translation stdout is only translated text. Diagnostics go to stderr only through `--debug` or `log_level = "debug"`.
- `zig build` is CPU-only. CUDA requires explicit `zig build -Dcuda=true`; `-Dcuda-lib-dir` must be absolute.
- The deterministic backend is build-time only through `-Dtest-backend=true`; do not add runtime fake-mode environment switches.
- Network access is allowed for explicit `kotoba models pull` flows only, never for normal `translate`.

## ANTI-PATTERNS (THIS PROJECT)
- Do not reintroduce removed external server config keys: `runtime`, `server_url`, `server_autostart`, `llama_server_path`, `server_startup_timeout_sec`.
- Do not make translation contact cloud APIs or remote endpoints.
- Do not persist source or translated bodies in logs/debug output; SQLite memory is the explicit storage path.
- Do not make tests depend on real internet, a real model, CUDA hardware, or an installed `curl`.
- Do not edit generated build output or vendor upstream code unless the task is explicitly about that boundary.
- Do not add backwards-compat aliases such as `gpu_layers = "auto"` or `"all"`; `gpu_layers` is signed integer only.

## COMMANDS
```bash
git submodule update --init --recursive
zig fmt build.zig src/*.zig src/cli/*.zig src/models/*.zig
zig build test
zig build
bash test/integration/smoke.sh
zig build bench
KOTOBA_CUDA_MODEL=/path/to/model.gguf bash test/integration/cuda_smoke.sh
```

## NOTES
- `vendor/llama.cpp/KOTOBA_VENDOR.md` records the pinned upstream commit. The nested upstream `.git` is intentionally omitted.
- `src/llama_api_probe.c` is compiled with `-fsyntax-only` during build to catch llama.cpp C API drift early.
- Markdown tables are intentionally left untranslated in v1 to preserve structure.
- `docs/superpowers/plans/` contains historical plans; use current docs/source/tests as truth when they diverge.
