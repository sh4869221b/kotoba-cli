# Ownership and allocator boundaries

This document records the current Issue #54 ownership contract. It describes
Zig-owned allocations only; it does not measure process RSS, native llama.cpp
allocations, or SQLite allocations outside the observed Zig owners.

## Terms

- **Owner**: the value that records allocator provenance and performs its
  matching `deinit` or `free` action.
- **Borrowed view**: a slice or value usable only while its documented owner
  remains alive and unchanged.
- **Invocation arena**: temporary command data whose lifetime ends when the
  public adapter returns. It is not a replacement allocator for retained
  translation results.

Slices alone do not establish ownership. An owner, its allocating allocator,
and its deinitialization site define the contract. All explicit owners in this
table are move-only by convention: `deinit()` invalidates their views, and it
is not an idempotence promise.

## Current ownership table

| Area | Owner and allocator provenance | Borrowed view and transfer | Replacement, failure, and deinit |
| --- | --- | --- | --- |
| `config.load` and `config.parse` | `OwnedConfig` owns `model_id`, `model_path`, and `log_level` with its stored allocator. File bytes are local to `load`. | `view()` returns `Config` borrowed until mutation or `deinit()`. | `setValue` duplicates a string before freeing its old owned value, so a validation/allocation failure retains the old value. Call `owned_config.deinit()`. |
| `config.default`, `save`, and `getValue` | `default()` contains literals and owns nothing. `save` owns its local page-allocator serialization buffer. `getValue` returns caller-allocator bytes. | Default fields are borrowed literals; a successful `getValue` return transfers to its direct caller. | `save` releases its buffer on success/error; every successful `getValue` result is freed by its direct caller. |
| `glossary.load` and `glossary.parse` | `OwnedGlossary` owns every term field and the term array with its stored allocator. The empty read-fallback is an owned zero-item value. | `view()` returns `Glossary` and `Term` fields borrowed until `deinit()`. | Partial parse cleanup releases initialized term fields and the array. Call `owned_glossary.deinit()`. |
| `models.load`, `loadReadOnly`, and `parse` | `OwnedList` owns the model array and every model field. `loadReadOnly` may parse the built-in template into that owner. `removeById` transfers an independent `OwnedModel`. | `OwnedList.view()` and `OwnedModel.view()` are borrowed until mutation or `deinit()`. `find` returns a borrowed model view. | Upsert/replacement clones before it frees old storage; partial parsing unwinds owners. Call the matching owner `deinit()`. |
| `models.registry.save` and `installedPath` | `save` owns its local page-allocator serialization buffer. `installedPath` transfers a caller-allocator joined path after releasing its temporary filename. | The successful `installedPath` return belongs to its direct caller. | `save` releases its buffer on success/error; the direct caller frees every `installedPath` result. |
| `markdown.protect` and `markdown.restore` | `markdown.Document` owns protected text, tokens, and originals with its creating allocator. `restore` returns caller-owned bytes. | Document and token views are borrowed from `Document`; warning slices are borrowed until copied into a longer-lived owner. | `Document.deinit(allocator)` releases all protected state. The caller frees restored bytes on every exit. |
| `translate.readInput`, `ProtectedSource`, and `translateSegments` | `readInput.text` and the accumulated `translateSegments` text are owned by their creating caller domain. `ProtectedSource` owns an optional `Document` and otherwise borrows its source text. | The `ProtectedSource` text is borrowed from its `Document` or from the input owner; accumulated segment text transfers only to its immediate caller. | The input/accumulated owner frees its bytes on success/error; `ProtectedSource.deinit` releases its optional document. |
| One backend call | `translation_contract.Result.text` transfers from the backend to its consumer and is freed with the allocator that created it. `Request` borrows model ID, source, languages, prompt, and timeout synchronously for that call. | `Result.text` may remain valid for the creating allocator's lifetime until its consumer deinitializes it; `Request` does not outlive the call. | `consumeResult` copies/accumulates accepted text and deinitializes every backend payload, including finish/error paths. Cache hit bytes are freed through `Db.allocator`, not the result or scratch allocator. |
| `translate.run` result | `output.OwnedResult` deep-copies translated text, optional source, model ID, runtime, the warning array, and every warning string with its stored result allocator. | `owned_result.view()` is a serializer view borrowed until `owned_result.deinit()`. It is move-only by convention. | Clone failures unwind every initialized field. The caller owns the successful return and calls `defer owned_result.deinit()`. |
| Translation working domains | `translate.run` receives the original reclaiming caller allocator. Its private implementation separates result, per-segment scratch, and stable session/DB domains. | Parse/prompt/segment/temporary Markdown values do not outlive their scratch call/segment domain. Stable session and DB values exist for one `translate.run` call. | Scratch is reset after segment work; stable DB/session state ends before `run` returns. Retained result data is never allocated from scratch. |
| JSON and output publication | `output.renderJson` returns bytes owned by its direct caller; `output.write` frees its local serialization buffer. `staged_output.Pending`/`Finished` own their paths and descriptors. | `output.Result` is a synchronous borrowed serializer input; literal test views remain legal. | `Pending.finish()` transfers to `Finished`; `publish` or `abort` consumes it. The existing staged-output #25 rules remain unchanged. |
| `cli.run` and public command adapters | `cli.run` owns an XDG/dispatch arena. Every public `src/cli/*_cmd.zig` adapter owns an invocation arena for argv-derived and command-local graphs. | `xdg.Paths`, parsed arguments, loaded config/registry/glossary views, and adapter helper values are borrowed only during that call. | Every arena is deferred on success and error. `translate_cmd` passes the original allocator to `translate.run`, owns the returned `OwnedResult` until output/publication completes, and then deinitializes it. |
| `doctor.run` and `main` | `doctor.run` owns its check/message graph in a local arena even when called directly. `main` owns the argv arena used by `Args.toSlice`. | Doctor checks and argv slices are borrowed only inside their scopes. | `main` computes the exit code, leaves the argv-arena scope, then calls `process.exit`; ordinary defers are therefore not bypassed. |

## Deinitialization examples

```zig
var cfg = try config.load(allocator, paths.config_file);
defer cfg.deinit();
const borrowed_cfg = cfg.view();

var result = try translate.run(allocator, paths, borrowed_cfg, opts);
defer result.deinit();
try output.write(.json, result.view(), true);
```

The adapter arena may own `opts` and other command data, but `translate.run`
uses the original allocator and its `OwnedResult` stays live through output.
No view from an adapter, `OwnedConfig`, `OwnedGlossary`, `OwnedList`,
`OwnedModel`, `Document`, or `OwnedResult` may be retained after its owner is
mutated or deinitialized.

## Bounded-work evidence and limit

The deterministic ownership tests retain results deliberately to distinguish
retained output from scratch. `runWithAllocators` makes result, scratch, and
stable session/DB domains separately observable; the public CLI path passes
the original allocator into `translate.run`. After 64 warmup calls, 2,048
measured calls with eight segments retain 2,112 result owners; scratch ends at
zero and its peak plateaus. Separate fixed-size calls with 64 and 2,048
segments record the same scratch peak (826) while retained result bytes rise
from 512 to 16,384, then all result, scratch, and stable counters return to
zero after teardown.

This is a fixed-input Zig allocation characterization that requires a
reclaiming allocator; a caller-supplied arena may retain backing storage until
the arena itself is deinitialized. It does not claim a bounded RSS, a bound on
native llama.cpp/SQLite allocations, real-model inference behavior, CUDA
behavior, or transaction/storage atomicity. In particular, allocate-before-free
for an in-memory string replacement is local atomic replacement; it is not an
atomic config or registry write guarantee.
