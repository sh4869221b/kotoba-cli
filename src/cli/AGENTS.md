# PROJECT KNOWLEDGE BASE

## OVERVIEW
`src/cli/` contains thin argv adapters for each `kotoba` command. Business rules live in parent modules such as `translate`, `models`, `config`, `doctor`, `memory`, and `glossary`.

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Parse common option patterns | `args.zig` | `ArgCursor` and `hasOptionValue`. |
| `kotoba init` | `init_cmd.zig` | Ensures XDG dirs, registry/glossary, config, memory DB. |
| `kotoba translate` | `translate_cmd.zig` | Flag parsing, debug notice, output destination. |
| `kotoba models ...` | `models_cmd.zig` | Registry mutation, model selection, deletion guard. |
| `kotoba doctor` | `doctor_cmd.zig`, `../doctor.zig` | Adapter only; diagnostics live one level up. |
| `config`, `memory`, `glossary` | matching `*_cmd.zig` | Keep output simple and scriptable. |

## CONVENTIONS
- Parse arguments left-to-right with `ArgCursor`; return `errors.Error.InvalidArguments` for unknown or malformed options.
- Keep command modules thin. If logic needs unit tests or reuse, move it to a parent module and call it here.
- Load config at the command boundary only when that command needs it.
- Call `xdg.ensureDirs` before commands that create or mutate XDG files.
- Human-readable success lines are short and stable, e.g. `initialized`, `imported ID`, `pulled ID`, `using ID`, `verified ID`.

## ANTI-PATTERNS
- Do not add implicit prompts that block automation; support explicit flags such as `--yes`.
- Do not make `translate_cmd` print debug text unless diagnostics are enabled.
- Do not parse model registry TOML or config directly here.
- Do not silently ignore extra positional arguments.
