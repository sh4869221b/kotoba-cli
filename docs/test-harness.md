# Test Harness Contract

This guide describes the isolated, deterministic checks for Kotoba CLI and
their supported boundaries. It does not add a CLI option, a runtime fake-mode
switch, a CI requirement, or a fault-injection framework.

## Backend request and result

The production and deterministic sessions share one typed contract. A request
borrows `model_id`, the complete `source_text`, resolved source and target
languages, the rendered prompt, and `timeout_sec` for the duration of one
call. A result owns its `text`; every caller must call
`Result.deinit(allocator)`, including when the finish reason becomes an
application error.

| `FinishReason` | Producer condition | Consumer behavior |
| --- | --- | --- |
| `eog` | End-of-generation token. | Success; append text and upsert the segment. |
| `max_tokens` | Generation limit reached. | Success; append text and upsert the segment. |
| `context` | Context/KV capacity was unavailable. | Return existing `LlamaDecodeFailed`; do not append or upsert this segment. |
| `timeout` | Request deadline elapsed. | Return existing `Timeout`; do not append or upsert this segment. |
| `decode` | Tokenization, token-piece conversion, or another decode failure. | Return existing `LlamaDecodeFailed`; do not append or upsert this segment. |

Timeout takes precedence when a decode status arrives after the deadline.
The embedded adapter maps status `1` to `context` and other nonzero decode
statuses to `decode`. The configured token limit remains a successful
`max_tokens` result. The consumer frees each returned buffer on every path;
successful cache writes from earlier segments are not rolled back when a
later segment fails.

The deterministic session has an instance-local optional fixture. An
explicit fixture copies arbitrary bytes exactly, including empty, whitespace,
invalid UTF-8, and truncated bytes. Without a fixture it returns
`JA:<source_text>` or `EN:<source_text>` according to `target_lang`. It uses
the structured source and target fields and never parses prompt markers.
Malformed bytes are payloads, not a new validation feature; #31 validation is
outside this harness.

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
zig test src/sys.zig -lc --test-filter 'fault io happy'
zig test src/sys.zig -lc --test-filter 'fault io failure'
zig test src/fs.zig -lc --test-filter 'fault fs happy'
zig test src/fs.zig -lc --test-filter 'fault fs failure'
zig test src/memory.zig -lc -lsqlite3 --test-filter 'fault sqlite happy'
zig test src/memory.zig -lc -lsqlite3 --test-filter 'fault sqlite failure'
zig test src/net.zig -lc --test-filter 'fault http happy'
zig test src/net.zig -lc --test-filter 'fault http failure'
zig test src/models.zig -lc --test-filter 'fault install'
zig test src/sys.zig -lc --test-filter 'fault boundary'
```

## Build snapshots and coordination

`harness_build_snapshot test|cpu|cuda` runs the non-default
`zig build test-artifacts` step with a private `--prefix`, then copies the
existing executable and unit-test executable to `BIN` and `UNIT_BIN`. The
`test` profile uses `-Dtest-backend=true`; `cpu` uses `-Dtest-backend=false`;
`cuda` uses `-Dtest-backend=false -Dcuda=true`. `test-artifacts` installs
artifacts without executing the unit tests.

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
zig build test
zig build test -Dtest-backend=true
zig build
bash test/integration/common.sh --self-test
bash test/integration/smoke.sh
bash test/integration/bench.sh
```

To inspect the installed artifacts without running the build's shared
`zig-out` executable, use a private prefix:

```bash
E="$PWD/.omo/evidence/issue-47"
mkdir -p "$E"
zig build test-artifacts -Dtest-backend=true --prefix "$E/task-5-artifacts"
"$E/task-5-artifacts/bin/kotoba-tests"
```

CUDA QA performs its preflight before building and is optional. On a machine
without both a model path and working `nvidia-smi`, this exact command should
exit successfully with the existing skip message:

```bash
env -u KOTOBA_CUDA_MODEL bash test/integration/cuda_smoke.sh
# SKIP cuda qa: missing KOTOBA_CUDA_MODEL or nvidia-smi
```

The repeated/concurrent check uses independent unit-test, smoke, and
benchmark processes. It runs 3 rounds by default; `--rounds` accepts an
integer from 1 through 1000. `--evidence-dir` must be an absolute path, and
invalid or out-of-range arguments exit with status 2 and
`parallel harness: invalid arguments`.

Run it with an absolute evidence directory:

```bash
E="$PWD/.omo/evidence/issue-47"
mkdir -p "$E/task-6-children"
bash test/integration/parallel.sh --rounds 3 --evidence-dir "$E/task-6-children" \
  >"$E/task-6-parallel.log" 2>&1
```

The driver records every child status, preserves parent sentinels, parses each
benchmark JSON with Python's standard library, and cleans only owned roots.

## Concurrency and coverage boundary

Tests involving process-global llama or logging state run serially inside each
unit-test process. Independent processes may run concurrently, which is the
boundary exercised by the repeated/concurrent driver. No default check claims
real model sampling, CUDA inference, network access, or curl availability.
The CPU default, explicit CUDA opt-in, quiet stdout, privacy boundary, and
network-free normal translation behavior remain unchanged.
