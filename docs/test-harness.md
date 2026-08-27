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
