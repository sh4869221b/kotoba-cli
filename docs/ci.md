# Linux CPU CI

## Support boundary

The required CI target is **Linux x86_64 CPU on Ubuntu 24.04**, with native
builds and official Zig **0.16.0**. Builds target the native host only; cross
compilation is unsupported. This does not establish release-artifact
coverage. macOS has a native CPU linker path but is unverified and not required;
Windows native builds are unsupported. Other architectures are outside this
job. Linux CUDA is an explicit opt-in build with manual, model-dependent smoke
checks, never a required job or a claim of hardware validation.

## Toolchain and clean checkout

Initialize the fixed llama.cpp submodule before any native build command:

```bash
git submodule update --init --recursive
mise exec -- zig version # must print 0.16.0
```

The native setup profile installs these distribution packages and reports their
exact resolved versions on every run; their package versions are not immutable
pins:

```bash
packages=(build-essential clang ccache cmake pkg-config libsqlite3-dev git ripgrep python3 xz-utils ca-certificates curl)
sudo apt-get update
sudo apt-get install --yes --no-install-recommends "${packages[@]}"
dpkg-query -W -f='${Package}\t${Version}\n' "${packages[@]}"
```

`.github/actions/setup-linux/action.yml` downloads the versioned official
`zig-x86_64-linux-0.16.0.tar.xz` archive, checks SHA-256
`70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00` before
extraction, and verifies `zig version` against `build.zig.zon`.

The `format` profile deliberately does not initialize the submodule, install
native packages, or require native tools. Its only pre-existing runner-tool
prerequisites are `git`, `python3`, `curl`, `xz`, and `sha256sum`, plus the
verified Zig installation. In contrast, `build`, `unit`, and every integration
child use recursive checkout and reject a missing, source-only, wrong, or
parent-fallback llama.cpp submodule before native work begins.

Network access is needed for setup (checkout/submodules, packages, compiler),
not for tests. `curl` is setup-only. Tests use local fixtures and controlled
loopback peers; no downloaded GGUF, external service or CUDA hardware is needed.
Normal translation remains network-free. An explicit model pull regression
uses a loopback positive control, not a completed internet download.

## Stages and local reproduction

`.github/workflows/linux-cpu.yml` runs on every pull request, pushes to `master`,
and manual dispatch, without path filters. It uses read-only `contents: read`,
a commit-pinned checkout with no persisted credentials, a 60-minute timeout per
job, and per-ref cancellation of stale runs. The exact check names are:

| Check name | Command | Required observations |
| --- | --- | --- |
| `Linux CPU / format` | `mise exec -- bash test/ci/linux.sh format` | Zig format and Git whitespace checks |
| `Linux CPU / build` | `mise exec -- bash test/ci/linux.sh build` | GCC and Clang production builds; pin, API probe, copied runner, cache and tool-failure contracts |
| `Linux CPU / unit` | `mise exec -- bash test/ci/linux.sh unit` | Positive executed CPU and deterministic unit counts, zero failures |
| `Linux CPU / integration` | strict aggregate over its three children | Requires `Linux CPU / integration / smoke`, `Linux CPU / integration / matrix`, and `Linux CPU / integration / parallel` all to report `success` |

Run all four locally, retaining evidence outside temporary HOME/XDG state:

```bash
E="$PWD/.omo/evidence/linux-ci"
for stage in format build unit integration; do
  KOTOBA_CI_EVIDENCE_DIR="$E/$stage" mise exec -- bash test/ci/linux.sh "$stage"
done
```

The optional evidence override must be absolute. Without it, the driver prints
results and retains evidence in a unique `kotoba-ci-evidence.*` directory under
`RUNNER_TEMP`, `TMPDIR`, or `/tmp`. Each stage records exact command, exit status,
stdout/stderr, tool versions, source SHA, vendor pin, actual counts and cleanup.
Before/after explicit Git porcelain snapshots include source, untracked files
and submodule state. A snapshot read error or drift fails the stage; unchanged
pre-existing dirt is allowed, and an already nonzero command status is preserved.
The build stage retains the default GCC build and uses `CC=clang CXX=clang++`
with a separate temporary local cache/prefix. It records CMake compiler metadata,
compiler version/runtime selection, dynamic linkage and both real CLI version
outputs. Clang is a build-only dependency, not a new application dependency.
The format and native stage jobs upload their stage evidence with `if: always()`
under the unique `linux-cpu-${github.run_id}-${github.run_attempt}-${stage}`
name and seven-day retention. The upload is only the runner-temp evidence
directory: it excludes release binaries, `.zig-cache`/ccache trees, and
credentials or other secrets. The aggregate has no stage evidence directory to
upload. This configuration is not proof that a hosted upload occurred.

The current exact-SHA local receipts record 300 executed CPU tests with one
separate skip and 301 deterministic tests with zero skips; both profiles record
zero failures. Counts are parsed from runner output, not promised constants.
They distinguish configured workload from an observed receipt, and the build
contract compares build and installed/copied stdin-closed `kotoba-tests` runs.

The full CLI matrix is unconditional and rejects absent/empty groups or missing
passing receipts. The current exact-SHA counts are recorded from the matrix
`summary.json`. Its standalone command is:

```bash
mise exec -- bash test/integration/cli_matrix.sh --evidence-dir "$PWD/.omo/evidence/cli-matrix"
mise exec -- bash test/integration/parallel.sh --rounds 3 --evidence-dir "$PWD/.omo/evidence/parallel"
```

`integration` accepts `--suite all|smoke|matrix|parallel`; its default is
`all`, and its default parallel setting is two rounds. The workflow runs the
three child jobs concurrently. `smoke` observes one common self-test and one
smoke run; `matrix` observes one common self-test and the full CLI matrix.
Each parallel round has nine children (four unit, two smoke, one benchmark,
two full matrices) and derives four unit logs, one benchmark, 15 benchmark
measurements, and two matrix receipts. Thus a two-round run observes 18
children, eight unit logs, two benchmarks, 30 measurements, the unit-test
executions recorded by its receipt, and four full matrix receipts. Pull requests configure one
parallel round; `master` pushes and manual dispatch configure two. These are
configuration and local-receipt facts, not evidence of a hosted schedule or
completed remote run. See [test-harness.md](test-harness.md#cli-contract-matrix)
for separate CLI and component observations and explicit #13/#31/#37 gaps. The checks cover
the bounded Issue #25 staged-publication contract; they do not establish
real-model quality, content/structure or empty-result policy, TM rollback, directory durability, or
protection against a hostile same-UID stage writer.

## Required-check configuration

A workflow file does **not** enable merge protection. The repository maintainer
must perform this procedure after observing the actual PR checks; this document
is not evidence that remote checks or settings have already been verified.

1. Record the PR head SHA and actual completed successful check runs for all four
   exact names above, including their GitHub Actions app IDs and run URLs. For
   merge-ref runs, associate the check suite with that PR head and merge candidate.
   Rerun once on the unchanged candidate and verify all four results again.
2. Read and save `GET /repos/OWNER/REPO/branches/master/protection` and
   `GET /repos/OWNER/REPO/rulesets?includes_parents=true`. Distinguish a genuinely
   unprotected branch from authentication/network errors. Re-read immediately
   before changing anything to detect concurrent updates.
3. For existing protection, PATCH only its `required_status_checks` subresource
   with the union of existing context/app pairs and the four observed pairs.
   Preserve strictness and every unrelated protection; preserve existing rulesets
   entirely. If the branch is genuinely unprotected and compatible with its
   rulesets, PUT minimal protection with `strict: true`, the four observed checks,
   `enforce_admins: true`, and null review/restriction objects. Generate the request
   from the freshly read JSON and submit a file, not shell-interpolated JSON.
4. Read protection and rulesets back. Assert all previous requirements/settings
   remain, all four context/app pairs are required, and rulesets are unchanged.
   Permission errors or conflicts block completion; never remove a protection or
   use an admin merge bypass to proceed.
5. Recheck the exact PR head, reviews and checks before a normal protected merge.
   Verify all four push checks on the resulting `master` merge SHA and read back
   required checks again. A changed candidate needs fresh relevant verification.

The status-check PATCH and context/app binding follow the
[GitHub branch-protection API](https://docs.github.com/en/rest/branches/branch-protection#update-status-check-protection).
The workflow token itself has no administration permission.

## Build cache and troubleshooting

The [embedded API contract](embedded-llama-api.md) fixes llama.cpp to
`9c92e96a64fe0f03f5f3e5ab720a151941da1de5`, validates Git checkout/index identity,
checks full CMake metadata and compiles exact C API signatures. Missing, wrong
or parent-fallback submodules fail explicitly. Restore the canonical checkout
with the initialization command above; do not suppress the guard or change the
pin to match an accidental local checkout.

CMake outputs live under `<local-cache>/llama.cpp/cpu` and `cuda`, defaulting to
`.zig-cache`. `--cache-dir` moves that local cache and `--prefix` selects the
installation directory. Old `vendor/llama.cpp/build-kotoba*` directories are
unused and never automatically removed. CI uses separate GCC and Clang
compiler caches at `${RUNNER_TEMP}/kotoba-ccache/gcc` and `/clang`; GCC native
output is `.zig-cache/llama.cpp/cpu`, while Clang native output is
`.zig-cache/ci-clang/llama.cpp/cpu`.

Each restore requests one exact key, with no restore-key prefix. Identity keys
include OS/architecture, compiler family and resolved compiler identity, the
llama.cpp pin and source/build inputs, and the relevant file hashes. A changed
identity invalidates the native key. `cache-matched-key` may be empty or must
equal the requested exact key; otherwise the job fails. Saves happen only after
a successful job and only after a cache miss. Therefore a restore action or a
key policy alone does not demonstrate a cache hit.

Native metadata is validated before use and stamped only after a valid build.
A corrupt manifest, CMake metadata, cache receipt, or integration receipt fails
the owning check; it is never repaired by deleting it or falling back to another
compiler/cache tree. For an inconsistent local cache, reproduce with a new
private cache/prefix rather than deleting reusable state:

```bash
scratch="$(mktemp -d)"
mise exec -- zig build --cache-dir "$scratch/cache" --prefix "$scratch/install"
```

Use the exhaustive cold/warm cache exercise only when requested; it is not part
of ordinary local checks or required CI cadence:

```bash
E="$PWD/.omo/evidence/native-cache-qa"
mise exec -- bash test/integration/build_contract.sh --case cache --native-cache-qa --evidence-dir "$E"
```

That QA creates private GCC and Clang caches, requires an initial native miss
followed by a validated warm hit, and records ccache metadata. Interpret its
`cache-hit`, matched-key, identity, and native manifest receipts together; do
not infer cold/warm state or speed from elapsed time. The Task 1 local receipt
observed GCC and Clang ccache counters of `0 -> 183`; it is not hosted-cache
evidence.

A probe type error requires checking the pinned API against the adapter, not
disabling compiler errors. Empty/mismatched count summaries fail the stage;
inspect raw runner logs and the known profile-specific skip. Invalid stage
arguments exit 2. Command failures stay nonzero, including the benchmark
sensitivity check:

```bash
KOTOBA_BENCH_EXPECT_MISMATCH=1 mise exec -- bash test/ci/linux.sh integration
# nonzero: benchmark validation failed: direct translated text mismatch
```

CUDA remains optional:

```bash
env -u KOTOBA_CUDA_MODEL mise exec -- bash test/integration/cuda_smoke.sh
# SKIP cuda qa: missing KOTOBA_CUDA_MODEL or nvidia-smi
```

That successful skip is not CUDA coverage. Use `-Dcuda=true` and a real model
only for explicit manual QA; requested CUDA builds fail if the toolkit or its
libraries are unavailable.

## Timing evidence

The evidence-only timing collector consumes saved GitHub API attempt and job
JSON; API timestamps, conclusions, job names, URLs, SHA, and attempt number
are authoritative. It rejects malformed, duplicate, incomplete, failed,
missing-page, and invalid-time input. The historical baseline contains five
unique successful attempts, each with four successful jobs. Its p50 critical
path is 863 seconds and p50 summed runner time is 1,695 seconds. Every report
row retains the URL, event, SHA, and attempt alongside raw provenance.

Critical path is the earliest required job start through the latest required
job completion. Queued workflow time starts at `run_started_at`, so it includes
pre-first-job waiting. Summed runner seconds add job durations and are neither
CPU time nor workflow wall clock. After the fan-out change, integration span
runs from the earliest child start through the latest child or aggregate
completion; the aggregate alone is not comparable to the former full job.

The Task 4 collector/self-test and raw baseline were task-local evidence, not
shipped files. A checkout after merge must not expect any `.omo` script or input
directory to exist. To collect the same historical raw API shape into an
arbitrary user-owned directory, use an authenticated `gh` session and these
read-only requests:

```bash
set -euo pipefail
repo=sh4869221b/kotoba-cli
capture="$(mktemp -d "${TMPDIR:-/tmp}/kotoba-ci-baseline.XXXXXX")"
for run_id in 33196864590 33198927396 33200066032 33211091243 33212330789; do
  gh api "repos/$repo/actions/runs/$run_id" >"$capture/$run_id.run.json"
  attempt="$(gh api "repos/$repo/actions/runs/$run_id" --jq .run_attempt)"
  gh api "repos/$repo/actions/runs/$run_id/attempts/$attempt" \
    >"$capture/$run_id.attempt-$attempt.json"
  gh api --paginate --slurp \
    "repos/$repo/actions/runs/$run_id/attempts/$attempt/jobs?per_page=100" \
    >"$capture/$run_id.attempt-$attempt.jobs.pages.json"
done
printf 'captured raw API responses in %s\n' "$capture"
```

The `ID.attempt-N.json` and `ID.attempt-N.jobs.pages.json` files retain the
stable attempt/job data shape used for the measurement. An independent
implementation can apply the formulas above to the five complete-success
attempts and take the median of their raw values to reproduce the historical
863-second critical-path and 1,695-second summed-runner p50s. The capture is
read-only but can still fail because runs may be unavailable or API access may
be denied; it is not a shipped summarizer or a claim that a new capture matches
the old source identity.

The baseline mixes `push` and `pull_request` events and source revisions, so it
is observational rather than a same-SHA cache experiment. No after/warm result
is claimed until a hosted capture supplies successful attempts and audited cache,
round, and revision sidecars. Workflow configuration does not prove branch
protection, hosted scheduling, cache hits, artifact uploads, or speed; hosted
proof belongs to Task 5.
