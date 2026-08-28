# PROJECT KNOWLEDGE BASE

## OVERVIEW
`src/cli/` contains argv adapters and command orchestration; `models_cmd.zig` coordinates acquisition modes, installation, registry updates, and selection through the parent `models` facade.

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Parse common option patterns | `args.zig` | `ArgCursor` and `hasOptionValue`. |
| `kotoba init` | `init_cmd.zig` | Ensures XDG dirs, registry/glossary, config, memory DB. |
| `kotoba translate` | `translate_cmd.zig` | Flag parsing, debug notice, output destination. |
| `kotoba models ...` | `models_cmd.zig` | Registry/HF/direct URL acquisition, selection, deletion guard. |
| `kotoba doctor` | `doctor_cmd.zig`, `../doctor.zig` | Adapter only; diagnostics live one level up. |
| `config`, `memory`, `glossary` | matching `*_cmd.zig` | Keep output simple and scriptable. |

## CONVENTIONS
- Parse arguments left-to-right with `ArgCursor`; return `errors.Error.InvalidArguments` for unknown or malformed options.
- Keep reusable parsing, validation, storage, and acquisition primitives in parent modules; command sequencing belongs here.
- Reject invalid argv before state access. `translate_cmd` rejects unknown dash-prefixed options, extra text, and text plus `--file` before loading config.
- Load config at the command boundary only when that command needs it.
- Keep `xdg.ensureDirs` and initialization on explicit mutation paths. Read-only commands must not create files or migrate state.
- `models list/info/verify` use `models.loadReadOnly`; `memory status` uses `memory.openReadOnly`; `config list` needs no config file.
- Human-readable success lines are short and stable, e.g. `initialized`, `imported ID`, `pulled ID`, `using ID`, `verified ID`.

## MODEL ACQUISITION
- `runPullWithAcquirer` separates registry ID, Hugging Face, and direct HTTPS modes; direct `--model-url` requires `--id` and `--checksum`.
- Keep the transient `request_model` separate from saved `m`: request queries reach the acquirer, while `models.url` derives safe persisted metadata.
- Acquire and verify before registry upsert; apply `--use` selection afterward. Model installation and registry/config writes are separate operations.
- Use the injected acquirer in command tests; use URL display helpers for `models info` rather than printing raw remote metadata.

## ANTI-PATTERNS
- Do not add implicit prompts that block automation; support explicit flags such as `--yes`.
- Do not parse model registry TOML or config directly here.
- Do not silently ignore extra positional arguments.
