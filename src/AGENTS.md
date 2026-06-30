# PROJECT KNOWLEDGE BASE

## OVERVIEW
`src/` is the Zig application layer for the `kotoba` binary: command orchestration, config/XDG, translation flow, embedded llama.cpp session, model management, memory, and output.

## STRUCTURE
```text
src/
|-- main.zig          # process entry, error rendering, refAllDecls test root
|-- cli.zig           # top-level command dispatch
|-- cli/              # per-command argv parsing and command adapters
|-- models.zig        # facade over model registry/download/checksum modules
|-- models/           # model registry, install, HF URL, validation
|-- translate.zig     # translation orchestrator
|-- llama.zig         # embedded llama.cpp session and C API wrappers
|-- backend.zig       # real vs build-time deterministic test backend
|-- config.zig        # TOML config contract
|-- memory.zig        # SQLite translation memory
`-- sys.zig           # thin OS/std wrappers used by tests and commands
```

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Add a command | `src/cli.zig`, `src/cli/<name>_cmd.zig`, `README.md`, `docs/design-v1.md` | Dispatch in `cli.run`, parse in submodule. |
| Change translate output | `src/translate.zig`, `src/output.zig`, `src/cli/translate_cmd.zig` | Preserve stdout contract. |
| Change config | `src/config.zig`, `src/config_tests.zig`, `test/integration/smoke.sh` | Update settable keys and smoke assertions together. |
| Change embedded runtime | `src/llama.zig`, `src/backend.zig`, `build.zig`, `docs/embedded-llama-api.md` | Keep API probe and docs aligned. |
| Add module | `src/main.zig` | Add to root `test { std.testing.refAllDecls(...) }`. |

## CONVENTIONS
- Prefer small modules with explicit allocator arguments and no global mutable state except tightly scoped runtime guards.
- CLI command modules return `!u8` exit codes and use `errors.Error` for user-facing failures.
- Public command behavior should be covered by module tests where cheap and by `test/integration/smoke.sh` when it crosses XDG/filesystem/process boundaries.
- Use project-owned parsers/helpers (`toml.zig`, `cli/args.zig`, `sys.zig`) instead of ad hoc parsing in command bodies.
- Keep `backend.TestSession` deterministic and available only through `-Dtest-backend=true`.

## ANTI-PATTERNS
- Do not let `translate` produce metadata on stdout for `plain` or `markdown`.
- Do not store source or translated bodies in debug logs.
- Do not make normal translation download models or call HTTP.
- Do not bypass model ID/path validation when writing files under XDG model directories.
- Do not add broad compatibility shims for removed server-runtime behavior.
