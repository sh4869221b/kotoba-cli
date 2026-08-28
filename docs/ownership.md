# Ownership and allocator boundaries

This document is the Issue #54 ownership specification. It records the
baseline at `b52940d2add1f37af84cbbe796d2d8ddb332aceb` and the owner APIs
planned by later Issue #54 todos. A **planned** owner is not implemented yet
and must not be used as evidence of current behavior.

## Terms

- **Owner**: the value responsible for one allocation and its eventual
  `deinit`/`free` action.
- **Borrowed view**: a slice or value usable only while its owner remains
  alive and unchanged.
- **Transfer**: successful return changes cleanup responsibility to the named
  caller. Failure leaves no newly transferred value.

Slices do not establish ownership on their own. The allocator that created an
allocation, its owner, replacement rule, and deinitialization site define the
contract.

## Allocation contract table

| Area and allocating entry point | Baseline owner and allocator provenance | Borrowed-view validity and successful transfer | Failure, replacement, and deinit rule | Planned Issue #54 boundary |
| --- | --- | --- | --- | --- |
| `config.load`, `config.parse` | `parse` duplicates configured string fields with the caller allocator; `load` first allocates file bytes with that allocator and releases those bytes before returning. The returned `Config` has slice fields but no explicit owner. | Consumers borrow the returned `Config` fields under the current mixed literal/allocated baseline. | Parser-local allocation failures unwind through parser cleanup; there is no public returned-value deinit contract yet. | **Planned:** `OwnedConfig` stores its allocator and owns `model_id`, `model_path`, and `log_level`; `view()` returns `Config`; `deinit()` releases exactly those strings. |
| `config.save`, `config.setValue`, `config.getValue` | `save` owns a page-allocator serialization buffer and deinitializes it locally. `setValue` may duplicate a replacement string with its caller allocator. `getValue` returns caller-owned formatted or duplicated bytes. | `getValue` transfers its return bytes to the caller. `Config` fields remain borrowed baseline values. | `save` releases its buffer on success and error. Scalar validation happens before mutation. String replacement must become allocate-before-free so an OOM leaves the old value valid; callers free every `getValue` return. | **Planned:** `OwnedConfig.setValue` performs atomic local replacement; only an `OwnedConfig` is deinitialized. |
| `glossary.parse`, `glossary.load` | `parse` allocates the term array and parsed term strings with its caller allocator. `load` reads file bytes with that allocator, releases the bytes, and currently converts any read error to an empty glossary. | `Glossary` and `Term` are borrowed shapes used by hashing and prompt construction. | Parsed partial allocation cleanup must release all already-created strings and the array. Preserve the broad read-error fallback while tightening only ownership cleanup. | **Planned:** `OwnedGlossary` owns every parsed term field and array, exposes `view()`, and releases them in `deinit()`. Empty fallback is an owning zero-item value. |
| `models.registry.load`, `loadReadOnly`, `parse` | Registry parsing allocates model arrays and parsed/default strings with the caller allocator. `loadReadOnly` may use an in-memory default template for a missing file. Returned `List` has no explicit owner. | `find(List, id)` returns a model view borrowed from the loaded list. | Parse errors must clean partial allocations. Loaded list/model cleanup is not an explicit boundary in the baseline. | **Planned:** `OwnedList` owns all model fields and its array; `view()` borrows until mutation or `deinit()`. |
| `models.registry.save`, `upsert`, `removeById`, `installedPath` | `save` owns and locally deinitializes its page-allocator serialization buffer. Registry mutation and serialization otherwise allocate through their caller allocator; URL metadata is sanitized before persistence. `installedPath` frees its temporary filename and transfers the caller-allocator joined path. | Caller-supplied `Model` fields are borrowed inputs in the baseline. The `installedPath` return is caller-owned. | `save` releases its buffer on success and error. Replacement/removal must not infer ownership from pointer or string contents; callers free every successful `installedPath` return. | **Planned:** `upsert` clones caller strings before replacing prior storage; `removeById` returns independent `OwnedModel` that survives list cleanup. |
| `markdown.protect` | `Document` allocates protected text, token storage, and token originals with its caller allocator. | `Document.text` and token views are borrowed from that `Document`. `translate.ProtectedSource` owns its optional `Document` and otherwise borrows source input. | `Document.deinit(allocator)` releases every owned part; partial protection failures must clean already-created parts. | **Implemented baseline:** retain this explicit `Document` contract. |
| `markdown.restore` | Returns caller-owned restored bytes and appends borrowed static warning slices to the supplied warning list. | Returned bytes transfer to the caller; warning slices are not owners. | Caller frees returned bytes on every path. Warning storage must be copied before it can outlive its source graph. | **Planned:** the eventual owned translation result deep-copies warning strings. |
| `translate.readInput`, `translate.translateSegments`, `translate.run` | These currently use the caller allocator for input bytes, glossary/Markdown graph, segment descriptors, prompts, backend result handling, accumulated translation bytes, warnings, optional DB, and the returned borrowed `output.Result`. | `readInput.text`, `TranslationResult.translated_text`, and `output.Result` fields are borrowed according to their current allocation lifetime. `translation_contract.Result.text` is caller-owned for one backend call. | `consumeResult` deinitializes each backend result. `translate.run` must release all intermediate bytes if a later operation fails. Cache hit text is released through the DB allocator that produced it. | **Planned:** private allocator seams separate result, per-segment scratch, and stable session/DB domains; `translate.run` returns `OwnedResult`. |
| `output.renderJson`, `output.write` | `renderJson(allocator, ...)` returns an owned `[]u8` allocated by its caller's allocator. `output.write` passes `page_allocator`, owns that returned JSON buffer, and frees it locally. `output.Result` itself is a borrowed serializer view so literal fixtures remain legal. | `renderJson` transfers its JSON bytes to its direct caller; `write` borrows `Result` synchronously and transfers no `Result` fields. | `renderJson` cleans partial array-list allocations on error. `write` frees the successful JSON buffer; callers must not free literal `Result` fields. | **Planned:** `OwnedResult.clone(allocator, Result)` deep-copies text, source, model, runtime, warning array, and warning strings; `view()` remains serializer input. |
| `translate.writeOutput`, staged output | Explicit output path derivation may allocate a path with the caller allocator. `staged_output.Pending` and `Finished` already own descriptors and paths. | `Pending.finish()` transfers ownership to `Finished`; `Finished.publish` or `abort` consumes that owner. | Derived paths are freed by `writeOutput`; every staged owner follows its existing finish/publish/abort/deinit lifecycle. | **Implemented baseline:** preserve the #25 staged-output owner contract without wrapping it. |
| `cli.run`, public `src/cli/*_cmd.zig` `run`, `doctor.run`, and `main` | Command orchestration currently passes a caller allocator through XDG path resolution, parsing, state loading, diagnostics, and argv collection. | Adapter arguments and loaded values are borrowed for the invocation. | Each allocating command path must release temporary command data before return; `main` must release argv storage before `std.process.exit`. | **Planned:** `cli.run` owns an XDG/dispatch arena, each public adapter owns a parse arena, `doctor.run` owns its diagnostic graph, and `main` owns a dedicated argv arena. |

## Allocator lifetime diagram

At the current baseline, one caller allocator flows through command parsing,
configuration, input, glossary, Markdown, segments, cache access, backend
calls, warnings, and returned translation fields. That makes the returned view
easy to couple accidentally to temporary storage.

Later todos split this into three domains. The command parse arena owns only
argv-derived and call-local values. A stable allocator owns the backend session
and optional database for the full `translate.run` call. A per-segment scratch
arena owns prompt and transient backend work, resets after every segment, and
is never the allocator for retained output. The result allocator owns the final
deep-copied `OwnedResult` and remains live until its caller calls `deinit()`.

The intended flow is therefore: command parse data feeds borrowed request
views; the translation call creates stable session/DB state; each segment uses
and resets scratch; final text and copied metadata transfer into the result
owner; call-local scratch and stable state are released before the caller
serializes the returned owner; then command output borrows that owner
synchronously and the caller releases the result owner.

## Invariants for later implementation

1. A replacement allocates and validates before freeing the old owned value;
   an allocation failure leaves the prior value usable.
2. `deinit` is called only for explicit owners, never for a borrowed literal
   `Config`, `Glossary`, `Model`, or `output.Result` view.
3. Backend `Request` remains borrowed for one call and every backend `Result`
   text is freed once with its allocation allocator.
4. A cache `Hit.translated_text` is freed through `Db.allocator`, even when
   result and scratch allocators differ.
5. Retained final output is measured separately from scratch. A zero scratch
   count after every call and a fixed-input post-warmup scratch-peak plateau are
   the bounded-work criteria; retained results are released only at their
   documented owner teardown.

This specification does not add a runtime measurement mode, change CLI output,
or change the existing glossary read-error fallback.
