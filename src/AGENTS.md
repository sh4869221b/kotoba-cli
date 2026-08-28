# PROJECT KNOWLEDGE BASE

## OVERVIEW
`src/` owns translation orchestration, runtime ownership, persistent state, and shared I/O boundaries; `cli/` and `models/` have their own guides.

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Translation/cache sequencing | `translate.zig` | `translateSegments` and `consumeResult` own session timing and cache acceptance. |
| Backend payload ownership | `translation_contract.zig`, `backend.zig`, `llama.zig` | Shared `Request`, `Result`, and `FinishReason` contract. |
| Config round trips | `config.zig`, `config_tests.zig`, `toml.zig` | Keep fields, key lists, parsing, serialization, and accessors aligned. |
| Read-only memory inspection | `memory.zig` | `openReadOnly`, sidecar/header preflight, statement lifetime. |
| Filesystem failure seams | `fs.zig` | `FileSystem` borrows an optional per-instance `Faults` controller. |
| Stream adapters and failure seams | `sys.zig` | POSIX stdin semantics, bounded reads, flushes, `ScriptedReader`/`ScriptedWriter`. |
| Request versus metadata URLs | `url.zig`, `net.zig` | Encoded request bytes, safe identities, redirect validation, bounded responses. |

## CONVENTIONS
- `Request` slices are borrowed for the translation call. Every `Result.text` is caller-owned, including empty and failed payloads; always call `Result.deinit`.
- `translateSegments` initializes one backend session lazily on the first translatable cache miss. Protected segments and cache hits do not initialize it.
- `consumeResult` accepts and caches `eog` and `max_tokens`. `timeout`, `context`, and `decode` fail without appending or caching that payload; earlier successful cache rows remain.
- Config changes must update `Config`, `settable_keys`, `parse`, `save`, `setValue`, `getValue`, and relevant `config_tests.zig` assertions together.
- `openReadOnly` resolves an existing database and checks WAL headers, WAL/SHM sidecars, and unsafe journals before opening SQLite. This protects stopped databases, not races with external writers.
- Use `url.zig` for request and metadata representations; `models/AGENTS.md` specifies the persistence rules.
- `net.zig` validates each redirect, limits redirect count, and rejects HTTPS-to-HTTP downgrades. Keep these checks at the request boundary.

## FAULT-TEST SEAMS
- `fs.Faults` and `memory.Faults` are caller-owned and borrowed by filesystem/database handles; controllers must outlive the handles and SQLite statements that use them.
- `sys.ScriptedReader`/`ScriptedWriter` borrow their buffers and short-I/O scripts. Keep values at stable addresses before exposing interface pointers, and keep borrowed storage alive through use.
- Fault schedules are per instance and one-shot, relative to the next matching operation. Reuse these seams for failure tests instead of process-global fault switches.
- SQLite injection happens before the C call and does not simulate SQLite side effects. Real locking, corruption, and transaction behavior need real local database fixtures.
- Writer acceptance is not delivery: buffered bytes are excluded from `bytes_written` until drained. Exercise flush failures through `writeWriterAll`.

## ANTI-PATTERNS
- Do not use schema-creating `memory.open` for read-only inspection or weaken preflight to assume `SQLITE_OPEN_READONLY` has no side effects.
- Do not return borrowed/static text from a backend result or retain request slices beyond the call.
- Do not turn an unsuccessful generation's partial text into a successful translation or cache entry.
