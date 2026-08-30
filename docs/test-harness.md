# Test Harness Contract

This guide describes the isolated, deterministic checks for Kotoba CLI and
their supported boundaries. It does not add a CLI option, a runtime fake-mode
switch or a fault-injection framework. The Linux CI stages that run these
checks and their required-check configuration are documented in [ci.md](ci.md).

## Backend request and result

The production and deterministic sessions share one typed contract. A request
borrows `model_id`, the complete `source_text`, resolved source and target
languages, the rendered prompt, and `timeout_sec` for the duration of one
call. A result owns its `text`; every caller must call
`Result.deinit(allocator)`, including when the finish reason becomes an
application error.

| `FinishReason` | Producer condition | Consumer behavior |
| --- | --- | --- |
| `eog` | End-of-generation token. | Validate complete UTF-8/no-NUL text, then append and upsert the segment. |
| `max_tokens` | Generation limit reached. | Validate complete UTF-8/no-NUL text, then append and upsert the segment. |
| `context` | Context/KV capacity was unavailable. | Return existing `LlamaDecodeFailed`; do not append or upsert this segment. |
| `timeout` | Request deadline elapsed. | Return existing `Timeout`; do not append or upsert this segment. |
| `decode` | Tokenization, token-piece conversion, or another decode failure. | Return existing `LlamaDecodeFailed`; do not append or upsert this segment. |

Timeout takes precedence when a decode status arrives after the deadline.
The embedded adapter maps status `1` to `context` and other nonzero decode
statuses to `decode`. The configured token limit remains a successful
`max_tokens` result when its complete text is encoding-valid. Empty, whitespace,
and valid partial results remain accepted. Finish-reason errors take precedence
even when the partial payload is malformed. The consumer frees each returned buffer on every path;
successful cache writes from earlier segments are not rolled back when a
later segment fails.

The deterministic session has an instance-local optional fixture. An
explicit fixture copies arbitrary bytes exactly, including empty, whitespace,
invalid UTF-8, and truncated bytes. Without a fixture it returns
`JA:<source_text>` or `EN:<source_text>` according to `target_lang`. It uses
the structured source and target fields and never parses prompt markers.
The arbitrary-byte fixture remains a component seam: consumer tests reject
malformed accepted results before storage/append without adding a runtime
fixture flag. Structural/content validation from #37 remains outside this
encoding contract; no malformed real-model generation CLI coverage is claimed.

## Private state and cleanup

Every integration script sources `test/integration/common.sh`, calls
`harness_init <suite>`, and uses the resulting variables:

```bash
source test/integration/common.sh
harness_init smoke
harness_build_snapshot test
# TMP, BIN="$TMP/bin/kotoba", and UNIT_BIN="$TMP/bin/kotoba-tests"
```

`harness_init` creates a unique `mktemp` root and private HOME plus all four
XDG bases below it. Model files, registries, SQLite memory, output files,
stdout/stderr/PTY captures, and build prefixes stay below that run's `TMP`.
Cleanup removes only the owned root, including after shell errors or signals;
there are no fixed shared `/tmp` capture paths and no deletion of an
unrelated pre-existing file. Unit fixtures that access the filesystem use
`std.testing.tmpDir` and own their paths directly.

The deterministic backend is a build-time choice. The normal `zig build test`
and `zig build` paths continue to compile the embedded production branch.

## Local-first CLI network regression

`bash test/integration/smoke.sh` runs the real copied CLI against a dynamic
loopback TCP observer. Each command receives a private fixture and records its
final connection count after the observer drains, stops, and joins. Local-only
`init`, `translate`, `doctor`, `config`, `glossary`, and `memory` cases must
have zero connections. An explicit HTTPS `models pull` is the positive control:
the observer must see a TCP connection, while the intentionally certificate-less
peer makes that fixture fail rather than claiming a completed HTTPS download.
This checks the CLI boundary with the deterministic backend; it does not claim
an operating-system-wide network sandbox or real-model inference coverage.

## Fault-boundary fixtures

Fault injection is explicitly supplied by tests through instance-local
controllers. Default production helpers use no controller and have no runtime
selector. The entrypoints are `sys.readReaderAlloc`, `sys.writeWriterAll`,
`sys.ScriptedReader`, and `sys.ScriptedWriter`; `fs.FileSystem` and
`fs.Faults`; `memory.Faults`, `memory.openWithFaults`, and
`memory.openReadOnlyWithFaults`; the private test-local
`net.TestHttpServer.startScript`; and the existing per-call downloader
argument to `models/install.zig`'s `acquireWithDownloader`.

`ScriptedReader` and `ScriptedWriter` borrow their caller's source, sink,
buffers, and script storage; take an interface pointer only after the fixture
has reached its final address, and keep every borrowed value alive through the
operation. `FileSystem` borrows its `std.Io`, `std.Io.Dir`, and optional
`Faults`. SQLite `Db` and every prepared `Stmt` retain the caller-owned
`Faults` pointer, so that controller must outlive both and statements must be
finalized before closing the handle. The controlled HTTP peer copies its raw
response scripts into heap-owned test state; stop and join it before releasing
that state. Filesystem and SQLite tests use `std.testing.tmpDir`, and cleanup
disarms controllers before closing or removing their private resources.

Each controller counts attempted matching operations before testing a positive,
one-based target ordinal. `arm` schedules relative to the next matching call
without resetting lifetime counters. A matching rule records its cause, fires
once, and disarms itself; explicit `disarm` leaves counters and the last cause
inspectable. Filesystem injection happens before open/truncate/write, rename,
or delete, so an injected `AccessDenied` or `NoSpaceLeft` does not claim that
the native operation ran. SQLite injection likewise occurs before open or step
and accepts only primary SQLite error codes 1 through 26, never success or
extended codes. Native writer failures remain the generic `WriteFailed`; a
fixture-specific cause such as `BrokenPipe` is only inspectable metadata.

These categories have different evidence. The default `sys` wrappers create a
real `FileSystem` for `sys.io()` and `sys.cwd()` with no controller, so their
boundary tests exercise actual private files and native write/rename errors.
SQLite also has separate real private-file lock and corruption tests. HTTP
tests use a controlled loopback peer with the real client and parser, not an
injected transport fault or an internet service. A declared `Content-Length`
that closes early keeps the current observed behavior: the available prefix is
returned successfully; this is a characterization, not a new rejection
policy. Prepared `BEGIN`, `COMMIT`, and `ROLLBACK` statements exist only to
test the SQLite primitive boundary and do not add an application transaction
API or recovery policy.

Run the focused groups from the repository root:

```bash
mise exec -- zig test src/sys.zig -lc --test-filter 'fault io happy'
mise exec -- zig test src/sys.zig -lc --test-filter 'fault io failure'
mise exec -- zig test src/fs.zig -lc --test-filter 'fault fs happy'
mise exec -- zig test src/fs.zig -lc --test-filter 'fault fs failure'
mise exec -- zig test src/memory.zig -lc -lsqlite3 --test-filter 'fault sqlite happy'
mise exec -- zig test src/memory.zig -lc -lsqlite3 --test-filter 'fault sqlite failure'
mise exec -- zig test src/net.zig -lc --test-filter 'fault http happy'
mise exec -- zig test src/net.zig -lc --test-filter 'fault http failure'
mise exec -- zig test src/models.zig -lc --test-filter 'fault install'
mise exec -- zig test src/sys.zig -lc --test-filter 'fault boundary'
```

## Build snapshots and coordination

`harness_build_snapshot test|cpu|cuda` runs the non-default
`zig build test-artifacts` step with a private `--prefix`, then copies the
existing executable and unit-test executable to `BIN` and `UNIT_BIN`. The
`test` profile uses `-Dtest-backend=true`; `cpu` uses `-Dtest-backend=false`;
`cuda` uses `-Dtest-backend=false -Dcuda=true`. `test-artifacts` installs
artifacts without executing the unit tests.

Zig 0.16.0 supplies the standard test runner. Both the build protocol and the
installed/copied `kotoba-tests` executable are exercised; the copied executable
runs without protocol arguments, with stdin closed and a 120-second bound.
CPU and deterministic counts must agree between build and direct execution.
Only the named deterministic `translateSegments` SQLite fault test skips in
CPU; skips are recorded separately, never counted as executed tests.

The helper holds a directory lock under the repository `.zig-cache` only
while building and copying the snapshot. It waits up to 600 seconds, reports
`test harness: build lock timed out` on timeout, releases only a lock acquired
by the current process, and releases the lock before executing any binary or
nested benchmark. A failed build or copy removes the candidate snapshot, so
an older executable cannot be run accidentally. The helper's self-check uses
its own scratch lock and verifies fixture isolation, error cleanup,
owner-only lock release, timeout preservation, and build/copy failure
propagation.

Raw `zig build` invocations that bypass this helper are not covered by the
parallel safety guarantee. Separate harness processes may execute snapshots
concurrently; the shared build lane remains coordinated.

## Reproducible checks

From the repository root, these checks require no model for the deterministic
and model-free paths:

```bash
mise exec -- zig build test
mise exec -- zig build test -Dtest-backend=true
mise exec -- zig build
mise exec -- bash test/integration/common.sh --self-test
mise exec -- bash test/integration/parallel.sh --self-test
mise exec -- bash test/integration/smoke.sh
mise exec -- bash test/integration/bench.sh
mise exec -- bash test/integration/cli_matrix.sh --evidence-dir "$PWD/.omo/evidence/cli-matrix"
```

To inspect the installed artifacts without running the build's shared
`zig-out` executable, use a private prefix:

```bash
E="$PWD/.omo/evidence/issue-47"
mkdir -p "$E"
mise exec -- zig build test-artifacts -Dtest-backend=true --prefix "$E/task-5-artifacts"
"$E/task-5-artifacts/bin/kotoba-tests"
```

CUDA QA performs its preflight before building and is optional. On a machine
without both a model path and working `nvidia-smi`, this exact command should
exit successfully with the existing skip message:

```bash
env -u KOTOBA_CUDA_MODEL mise exec -- bash test/integration/cuda_smoke.sh
# SKIP cuda qa: missing KOTOBA_CUDA_MODEL or nvidia-smi
```

The repeated/concurrent check uses four unit-test, two smoke, one benchmark,
and two complete CLI matrix processes per round (nine children). It runs 3
rounds by default; `--rounds` accepts an
integer from 1 through 1000. `--evidence-dir` must be an absolute path, and
invalid or out-of-range arguments exit with status 2 and
`parallel harness: invalid arguments`.

The CI driver is separate from that local default: `integration --suite` accepts
`all`, `smoke`, `matrix`, or `parallel`, defaults to `all`, and defaults to two
parallel rounds. Its workflow runs smoke, matrix, and parallel as three child
jobs, then accepts the required aggregate only when every child is `success`.
Pull requests configure one parallel round; `master` pushes and manual dispatch
configure two. Current exact-SHA local receipts observed 367 matrix cases
(48 translate, 251 commands, 23 memory, 45 files); a two-round parallel receipt
observed 18 children, eight unit logs, two benchmarks, 30 benchmark measurements,
2,624 unit-test executions, and four 367-case matrix receipts. These observations
do not prove a hosted schedule or run.

Run it with an absolute evidence directory:

```bash
E="$PWD/.omo/evidence/parallel"
mkdir -p "$E"
mise exec -- bash test/integration/parallel.sh --rounds 2 --evidence-dir "$E"
```

The driver records every child status and start/finish timestamps, preserves
parent sentinels, parses each benchmark JSON, and cleans only owned roots.
Each `parallel.*/round-N-matrix-M/cli-matrix.*` subtree retains the full matrix
receipts. `matrix-verification.json` records distinct temporary roots and
profile executables, nonempty groups, and overlapping matrix child lifetimes
in each round. Builds still serialize through the shared lock; this is process
concurrency, not simultaneous raw Zig builds. `cleanup.json` records the removed
parent root, released lock ownership and reaped child PIDs. An explicit external
evidence directory retains these artifacts after cleanup.

`parallel.sh --self-test` uses fake children only for lifecycle verification:
an early matrix child exits 7 followed by a successful child, the aggregate
must fail, restored children must pass, and a signal must remove the owned
root and reap descendants. These are helper checks, not product CLI coverage.

## CLI contract matrix

The Linux integration stage unconditionally runs this full matrix and the
parallel harness, and verifies all four group counts against passing case
receipts. The stable entrypoint for automation is:

```bash
mise exec -- bash test/integration/cli_matrix.sh --evidence-dir "$PWD/.omo/evidence/matrix"
# Optional focused selection; default is all four groups.
mise exec -- bash test/integration/cli_matrix.sh --group translate --evidence-dir "$PWD/.omo/evidence/translate"
mise exec -- bash test/integration/cli_matrix.sh --group commands --evidence-dir "$PWD/.omo/evidence/commands"
mise exec -- bash test/integration/cli_matrix.sh --group memory --evidence-dir "$PWD/.omo/evidence/memory"
mise exec -- bash test/integration/cli_matrix.sh --group files --evidence-dir "$PWD/.omo/evidence/files"
mise exec -- bash test/integration/cli_matrix.sh --self-test --evidence-dir "$PWD/.omo/evidence/helpers"
```

The current matrix records 367 measured CLI cases: translate 48,
commands 251, memory 23, files 45. Counts come from each run's `summary.json`; never
infer a pass from a historical total. Setup calls are captured separately,
not counted as cases.
Every selected group must run at least one case; missing files, duplicate IDs,
unfinished cases, failed assertions and harness timeouts fail the suite.
The per-command limit is 120 seconds and the suite limit is 20 minutes. A
harness timeout is not evidence of Kotoba's application `timeout` error.
The runner builds separate private `test` and `cpu` snapshots. Only
`commands-translate-cpu-model-missing` uses CPU; a deterministic session does
not check whether its configured model file exists.

Each `cli-matrix.*/cases/ID/receipt.json` identifies `level=cli`, group, actual
argv array, executable profile and SHA-256, stdin SHA-256, process status,
raw stdout/stderr, stdout sink, before/after FS and TM snapshots, and assertion verdicts.
`tm-broken-stdout-pipe` records a closed pipe read end before producer exec and
the direct producer return code; it never substitutes a consumer's status.
Captured paths are relative to the case evidence directory; executable and
fixture paths describe the original, subsequently removed temporary tree.
FS entries are sorted relative paths with type, mode, symlink target or content
hash, including SQLite/journal entries. Access times are excluded. TM is
observed through a separate SQLite URI `mode=ro` connection: absent and
unreadable are explicit states, never silently treated as zero rows. Readable
state includes column names, ordered row values and hit counts. The observer
does not initialize or repair a database. `summary.json` lists every case and
group count; `cleanup.json` records removed TMP and released lock ownership.
Evidence contains synthetic source/translation fixtures; no user state is read.

Issue #63 adds 30 strict-XDG command cases with redacted environment classes
(`unset`, `empty`, `absolute`, or `relative`) rather than raw values. The exact
new IDs are `commands-xdg-all-absolute-home-{unset,empty,relative}`;
`commands-xdg-{config,data,cache,state}-{unset,empty,relative}`;
`commands-xdg-mixed-domains`; `commands-home-fallback-{unset,empty,relative}`;
`commands-doctor-xdg-fallback-{human,json}`;
`commands-doctor-xdg-unresolved-{human,json}`;
`commands-doctor-xdg-special-json`; `commands-doctor-xdg-c1-{human,json}`;
`commands-doctor-xdg-non-utf8-json`;
`commands-home-unresolved-{readonly,init}`;
and `commands-xdg-relative-init`. Each receipt records the executable SHA-256,
argv, cwd, streams, status, environment classes, and independent expected-path
assertions. Doctor and unresolved-command cases require unchanged FS/DB
snapshots; the relative-XDG `init` case requires only HOME-derived paths.

Issue #54 adds two real CLI characterizations without using a subprocess as
an allocator measurement. `commands-config-string-replacements` performs five
preparatory string replacements plus one measured final replacement in one
initialized fixture, preserves their setup captures, and checks the final TOML
value set. `commands-models-remove-then-use-removed`
captures a successful removal, then proves a use of that removed ID returns
`model_registry_invalid` without changing the reset config, registry, or
managed-file state. The existing `files-atomic-native-prefix{,-absent}`
failure receipts precede fresh-fixture `files-atomic-mode-{600,640}` successful
publication receipts; their final evidence index does not claim recovery
inside one CLI process or one persisted state.

The matrix's JSON success cases prove the exposed empty `warnings` array,
plain/Markdown/JSON serialization, and `--include-source`. A nonempty warning
is currently covered by direct `OwnedResult` and Markdown component tests,
because the deterministic CLI path does not expose one without changing output
routing or the backend. The matrix therefore makes no invented nonempty-warning
CLI claim.


The commands group includes `strict61-` persistence cases: exact config
set/get and registry string round trips checked by independent `tomllib`,
malformed/unknown/duplicate/schema state, native directory/size/permission
errors, and human/JSON doctor reports. Each rejected-operation case seeds an
actual SQLite row and requires exact exit/stdout/stderr plus equal filesystem bytes, modes,
entries, mtimes, and logical database state. The operation matrix includes
init, use, remove, import with `--use`, registered/direct-URL/Hugging Face
pulls with `--use` (including HF metadata discovery), config set and model
list. Failed preflight must return before acquisition; these cases require no
model or remote service.

For native permission cases the observer runs as an ordinary non-root UID.
It snapshots readable state, changes only the target file to mode `000` for
the actual child, and restores its original mode in `finally` before the
second snapshot. `receipt.json.permission` distinguishes snapshot and execution
modes and records UID/EUID and restoration. A root-run suite fails explicitly
instead of silently skipping this proof. The helper self-test exercises both
normal child completion and a signal-terminated child; it is observer coverage,
not product coverage. These are pre-read permission faults, not mid-write
atomicity or crash-durability tests.

JSON assertions parse the real stdout. Success has exactly `source_lang`,
`target_lang`, `mode`, `model_id`, `runtime`, `cached`, `cache_status`,
`cached_segments`, `total_segments`, `translated_text`, `warnings`, `elapsed_ms`;
`source_text` is added only with `--include-source`. Strings remain strings,
`cached` is boolean, warnings are a string array, and counts/time must be
nonnegative integers (booleans rejected). Only elapsed time's type/range is
normalized, not translated bytes or counters. Error JSON is exactly
`{"error":{"code":string,"message":string}}`; doctor is exactly `ok:boolean`
and `checks:[{name,status,code,message:string}]`. If file routing wins over
`--format json`, stdout is empty and the file contains translated bytes, so no
JSON response is claimed. The helper self-test's synthetic zero-segment Result
uses `cached=false` and `cache_status=none`; it is not the real nonempty
all-protected CLI case.

### Measured CLI rows (`level=cli`)

Braced alternatives below expand to exact case IDs; full IDs are in each
summary. All rows assert real status, both streams, and FS/TM state.

| Axis and case IDs | Status and streams | FS / TM observations |
| --- | --- | --- |
| `translate-{en-ja,ja-en}-{direct,stdin,txt,md}-{plain,markdown,json}` (24) | 0; exact text or parsed JSON, empty stderr; file routing has empty stdout | Input unchanged; only designated sibling created; no TM changes |
| `translate-{multiline-plain,multiline-json,include-source-json,technical-json}` | 0; quotes, backslash, tab, newline and UTF-8 preserved; include-source and technical fields checked | FS/TM unchanged |
| `translate-text-contract-valid-json` | 0; standard JSON parser recovers every U+0001–U+001F, Japanese, emoji and combining mark; exact source and `JA:` translation bytes | FS/TM unchanged |
| `translate-text-contract-{invalid-stdin-human,nul-stdin-json,truncated-file,nul-file}` | 1; exact human `invalid_utf8` or parsed `embedded_nul` envelope; NUL supplied through stdin/file | Input and TM unchanged; rejected output absent |
| `translate-text-contract-{invalid-glossary,nul-glossary}`; `commands-glossary-text-contract-{utf8,nul}` | 1; exact encoding error, no success line or rejected body | FS/TM unchanged |
| `tm-text-contract-legacy-{source,output}-{utf8,nul}` | 1; parsed encoding error only; copied CLI selects normally seeded then raw-corrupted row | Read-only SQL captures full hex/BLOB lengths, all keys, counts/timestamps and DB hash before/after; exact equality and no sidecars |
| `tm-text-contract-unicode-hit` | 0; full cache hit, exact Unicode translation | Same row/text/keys/created timestamp, hit count +1; existing updated timestamp behavior |
| `translate-debug-{flag,config,json}` | 0; exact debug diagnostic on stderr, no source/translated bodies there | FS/TM unchanged |
| `translate-markdown-{fenced,inline,table,link-url,all-protected}` | 0; protected bytes preserved; tables untranslated; no quality claim | FS/TM unchanged |
| `translate-empty-{direct,stdin,file}` | 2; empty stdout, exact human `invalid_arguments` | FS/TM unchanged |
| `commands-{version,init-yes,config-list-ready,config-get-default,config-set,models-list,models-info,models-import,models-pull,models-use,models-verify-explicit,models-remove,glossary-ready,memory-status,memory-clear}` | 0; exact command-specific streams; local `file://` pull | Exact creation/update/removal sets; clear removes seed row; status preserves it |
| `commands-{top-missing,top-invalid,init-invalid,config-invalid,config-get-arity,models-info-arity,glossary-arity,doctor-arity,memory-clear-arity-absent-db}` and other family arity cases | 2; exact `invalid_arguments`; JSON variants `commands-{invalid-json,doctor-invalid-json}` have parsed error stdout and empty stderr | Initialized failures unchanged; absent-state mutations characterized separately |
| `commands-doctor-{ready,absent,missing-db}-{human,json}` | 0 ready / 1 absent or missing DB; exact human or typed JSON, empty stderr | Does not create missing state |
| `commands-xdg-all-absolute-home-{unset,empty,relative}`; `commands-xdg-{config,data,cache,state}-{unset,empty,relative}`; `commands-xdg-mixed-domains`; `commands-home-fallback-{unset,empty,relative}`; `commands-doctor-xdg-{fallback,unresolved,c1}-{human,json}`; `commands-doctor-xdg-special-json`; `commands-doctor-xdg-non-utf8-json`; `commands-home-unresolved-{readonly,init}`; `commands-xdg-relative-init` (30) | Parsed doctor checks are ordered `config_path`, `data_path`, `cache_path`, `state_path`; direct/unset is `ok`, empty/relative fallback is `warn`/`xdg_path_invalid`, unresolved is `error`/`path_resolution_failed`; accepted C1 controls are deterministic textual escapes in human and JSON output | Diagnostic and unresolved ordinary-command receipts preserve FS/TM; relative-XDG init creates only HOME fallback state |
| `commands-translate-{invalid-human,conflicting-inputs,unsupported-pair,absent-config,no-selection,cpu-model-missing}` | 2 invalid/conflicting; otherwise 1, exact respective error; CPU missing file is `model_missing`, distinct from `model_not_selected` | No FS/TM changes |
| `commands-{models-list-absent,models-invalid-absent,models-list-arity-absent,memory-status-absent-db,memory-invalid-absent-db}`; `commands-translate-unknown-token` | List/status 0, invalid/arity and unknown initial option 2 | Inspection and rejected argv preserve absent state; model list uses an in-memory default registry without writes |
| `tm-{miss,full-hit,partial-hit}` | 0; parsed JSON; partial has `cached_segments=1,total_segments=2` (two translatable paragraphs) | Miss +1 row; full +0 rows / hit +1; partial +1 row / prior hit +1 |
| `tm-broken-stdout-pipe` | 1; read end closed before exec, empty stdout, exact `kotoba: io_error: BrokenPipe` stderr; receipt records producer return/status, not a consumer status | TM commits the accepted `Matrix broken stdout pipe` -> `JA:Matrix broken stdout pipe` row before stdout failure; row count is 1 |
| `tm-disabled-{flag,config}`; `tm-{directory-open-failure,corrupt-open-failure,statement-failure}` | Disabled/open failure 0 uncached, empty warnings; incompatible table 1 with parsed `sqlite_failed`; empty stderr | Disabled sentinel unchanged; invalid DB/directory unchanged, no replacement or new translation |
| `glossary-{prefer,protect,hash-change,disabled-flag,disabled-config,empty-key-reuse,empty-key-reuse-config}` | 0; parsed JSON; no deterministic glossary substitution claim | Hash change/disable uses distinct key; disabled empty-glossary key reuse hits |
| `glossary-invalid-before-tm{,-absent}` | 1; parsed `glossary_invalid`, empty stderr | Existing sentinel or absent DB stays unchanged |
| `files-explicit-{direct,stdin,txt,md}-{plain,json}`, `files-default-sibling-{md,markdown}` | 0; empty stdout/stderr; exact translated destination bytes | Only destination created; no TM changes |
| `files-{overwrite,alias-overwrite}-{enabled,disabled}` | 0; empty streams | Destination replaced, including source alias; TM +1 enabled / unchanged disabled |
| `files-{output-exists,alias-exists,directory-exists,missing-parent,directory-open}-{enabled,disabled}` | 1; empty stdout, exact `output_exists` or Linux `io_error` (`FileNotFound` / `IsDir`) | Destination bytes/entries and siblings preserved, but fresh source already cached (+1 row) when enabled; no-memory unchanged |
| `files-{empty-direct,empty-stdin,empty-file,conflicting-input,missing-input}-{enabled,disabled}` | 2 `invalid_arguments` or 1 `io_error: FileNotFound`; empty stdout | Fail before translation; destination and TM unchanged |
| `files-atomic-native-prefix{,-absent}` | 1; exact `io_error: FileTooBig`, empty stdout | A real 1024-byte child file-size limit stops the CLI stage before publication; existing destination is byte-for-byte unchanged, absent destination remains absent, and no stage remains |
| `files-atomic-{mode-600,mode-640}` | 0; empty streams | Existing regular destination mode is retained after replacement |
| `files-atomic-{symlink,dangling,hardlink}-{reject,replace}` | Reject: 1 `output_exists`; replace: 0 | No-overwrite treats link entries as existing; overwrite replaces only the named link entry and preserves the symlink/hardlink referent bytes |
| `files-atomic-parent-permission` | 1; exact `io_error: AccessDenied`, empty stdout | Destination and entry set remain unchanged; fixture permission is restored during cleanup |
| `commands-models-remove-permission` | 1; exact `io_error: AccessDenied`, empty stdout | Managed-model deletion failure is not reported as `removed`; registry partial-state rules remain separate |

Finalized initialization regression #9 remains in `smoke.sh` and
`commands-init-remote-rejected`: URL-only init exits 1 with pull/model-path
guidance and `model_missing`, without downloading. The original smoke network
observer still checks zero local-command connections and the explicit pull
positive control. The separate `bash test/integration/secret_urls.sh` retains
#36's real CLI rejection, redaction and migration coverage; its signed-download
success proof is explicitly an injected-downloader component test, not real
HTTPS success. Neither regression is replaced by a matrix helper.

### Component rows and remaining gaps

These named inline tests run via `zig build test -Dtest-backend=true`.
Their returned errors and state are `level=component`: CLI argv, streams and
exit status are **N/A**. The CPU unit profile skips only the test requiring
`translateSegments`' deterministic backend; the deterministic profile executes it.

| Exact test name (module) | Component observable / limitation |
| --- | --- |
| `result consumer frees failed partial payloads without appending or caching them` (`translate`) | Timeout maps to `Timeout` / `timeout`; context/decode to `LlamaDecodeFailed` / `llama_decode_failed`; failed payload not appended/cached, previous row retained, allocator cleanup checked |
| `translateSegments sqlite lookup and upsert failures retain prior rows and fresh fixtures recover` (`translate`) | Borrowed faults at relative step 3/4 return `SqliteFailed`; exact counters and independent read-only observer prove first row retained, second absent; fresh fixtures recover |
| `result consumer accepts valid completed and token-limited text` (`translate`) | `eog` and `max_tokens` append/cache full Unicode, valid partial, empty and whitespace bytes unchanged |
| `result consumer rejects invalid accepted text before persistence`; `result consumer preserves finish error precedence for malformed bytes` (`translate`) | FF/NUL/truncated sequences reject before append/cache with/without DB; timeout/context/decode retain original errors; prior output/rows and allocator cleanup checked |
| `sqlite column text copies exact byte lengths`; `memory rejects invalid legacy text before bump` (`memory`) | Low-level transport copies legacy NUL without truncation; core lookup rejects malformed rows before mutation |
| `JSON text contract round trips every emitted variable field`; `JSON text contract rejects invalid emitted fields` (`output`) | Standard-parser exact controls/Unicode for each emitted string; malformed UTF-8/NUL reject; omitted source stays omitted; allocation failures clean up |
| `restore appends warning when token missing` (`markdown`) | Warning-only success; returned text stays `translation without protected tokens`; #37 |
| `writeOutput rejects existing destination without overwrite` (`translate`) | `OutputExists`, existing `old` bytes unchanged |
| `fault fs failure injected write preserves data and entry set`; `fault fs failure rename preserves existing and absent destinations` (`fs`) | Pre-operation injected failure preserves bytes/entries; not mid-write atomicity |
| `fault io failure prefix and broken pipe cause`; `fault io failure deferred flush independent counters disarm and rearm`; `fault io failure full caller owned sink is bounded` (`sys`) | `WriteFailed`, partial/pending bytes and recorded `BrokenPipe`/`NoSpaceLeft` causes; not real CLI stdout failure |
| `fault io failure read limit prefix independent instances and rearm` (`sys`) | Reader failure/limit, consumed prefix, independent counters and recovery |
| `checked close {happy,failure,reuse}` (`file_close`) | A real owned descriptor is consumed once; injected late errno is recorded only after the real close; repeated cleanup cannot close a descriptor reused by an unrelated sentinel |
| `staged output {happy,failure,gate,race,path,cleanup}` (`staged_output`) | Same-parent exclusive stage, exact finished bytes, captured modes, caller gate, collision/no-replace/path/link behavior, and cleanup ownership. Native prefix writes use real stage bytes; injected flush/sync/close/rename labels remain component evidence. |
| `writeOutput failure boundaries propagate native errors without publication` (`translate`) | Existing and absent output targets retain the expected state across the staged write boundary; no CLI stream/status is inferred from this component test |
| `models remove strict {baseline normal missing shared external,native directory deletion failure,injected reload failure,native registry directory before reload,managed root realpath failure,candidate realpath failure,remaining reference realpath failure,injected deletion failure}` (`cli/models_cmd`) | Config preflight fails before mutation; missing managed file remains benign. Native registry-directory reload is `IsDir`, injected reload stays `ModelsInvalid`; realpath/reload/deletion failures propagate without `removed`. Registry removal may already be saved, with config/model retained; no transaction or rollback is added |

| Level | Unproven or deferred guarantee | Owning follow-up |
| --- | --- | --- |
| covered | `tm-broken-stdout-pipe` closes the stdout read end before the real CLI producer exec, fixes producer exit/status and captured streams, and verifies the committed accepted TM row remains after `BrokenPipe` | [#13](https://github.com/sh4869221b/kotoba-cli/issues/13) |
| bounded | Issue #25 covers normal write/flush/sync/checked-close/rename failures through a same-parent stage. Native RLIMIT CLI failure and real component prefix bytes are distinct from injected late boundaries. It does not promise TM rollback, directory fsync/power-loss durability, process-kill cleanup, or adversarial same-UID stage-tampering protection. | [#25](https://github.com/sh4869221b/kotoba-cli/issues/25) |
| gap | Rejecting token-limited results: `max_tokens` currently succeeds and caches | [#31](https://github.com/sh4869221b/kotoba-cli/issues/31) |
| covered | Rejected argv and read-only commands preserve absent state; unknown initial options are rejected. This does not establish concurrent-writer safety. | [#32](https://github.com/sh4869221b/kotoba-cli/issues/32) |
| gap | Content/structure and empty-result policy, including missing protected-token rejection; encoding-valid empty text is accepted and missing tokens only warn | [#37](https://github.com/sh4869221b/kotoba-cli/issues/37) |

Characterizations record today's behavior, not endorsements or permanent
guarantees. Component failures do not invent corresponding CLI streams/status.
No matrix case claims real-model quality, GPU execution or real generation
timeout/decode faults, and no default test needs internet, a model or curl.

## Concurrency and coverage boundary

Tests involving process-global llama or logging state run serially inside each
unit-test process. Independent processes may run concurrently, which is the
boundary exercised by the repeated/concurrent driver. No default check claims
real model sampling, CUDA inference, network access, or curl availability.
The CPU default, explicit CUDA opt-in, quiet stdout, privacy boundary, and
network-free normal translation behavior remain unchanged.
