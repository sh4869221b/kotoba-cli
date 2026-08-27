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

Initialize the fixed llama.cpp submodule before any build command:

```bash
git submodule update --init --recursive
zig version # must print 0.16.0
```

The Ubuntu setup installs these distribution packages and reports their exact
resolved versions on every run; their package versions are not immutable pins:

```bash
packages=(build-essential clang cmake pkg-config libsqlite3-dev git ripgrep python3 xz-utils ca-certificates curl)
sudo apt-get update
sudo apt-get install --yes --no-install-recommends "${packages[@]}"
dpkg-query -W -f='${Package}\t${Version}\n' "${packages[@]}"
```

`.github/actions/setup-linux/action.yml` downloads the versioned official
`zig-x86_64-linux-0.16.0.tar.xz` archive, checks SHA-256
`70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00` before
extraction, and verifies `zig version` against `build.zig.zon`.

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
| `Linux CPU / format` | `bash test/ci/linux.sh format` | Zig format and Git whitespace checks |
| `Linux CPU / build` | `bash test/ci/linux.sh build` | GCC and Clang production builds; pin, API probe, copied runner, cache and tool-failure contracts |
| `Linux CPU / unit` | `bash test/ci/linux.sh unit` | Positive executed CPU and deterministic unit counts, zero failures |
| `Linux CPU / integration` | `bash test/ci/linux.sh integration` | Harness self-test, smoke, full CLI matrix and two parallel rounds |

Run all four locally, retaining evidence outside temporary HOME/XDG state:

```bash
E="$PWD/.omo/evidence/linux-ci"
for stage in format build unit integration; do
  KOTOBA_CI_EVIDENCE_DIR="$E/$stage" bash test/ci/linux.sh "$stage"
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
The GitHub step summary contains identity/status/counts; these jobs do not
publish downloadable release binaries or promise uploaded evidence artifacts.

CPU currently executes 138 passing tests and skips the one deterministic-only
`translateSegments sqlite lookup and upsert failures retain prior rows and fresh
fixtures recover` test. The deterministic profile executes all 139. Counts are
parsed from actual runner output, not hard-coded totals; skips are separate from
executed tests. The build contract compares CPU/deterministic build counts with
installed, copied, stdin-closed `kotoba-tests` runs and checks the exact skip name.

The full CLI matrix is unconditional and rejects absent/empty groups or missing
passing receipts. It currently records 155 cases: translate 39, commands 65,
memory 17, files 34. Its standalone command is:

```bash
bash test/integration/cli_matrix.sh --evidence-dir "$PWD/.omo/evidence/cli-matrix"
bash test/integration/parallel.sh --rounds 3 --evidence-dir "$PWD/.omo/evidence/parallel"
```

Each parallel round has nine children: four unit, two smoke, one benchmark,
and two full matrices. Two CI rounds therefore have 18 children and eight unit
logs. See [test-harness.md](test-harness.md#cli-contract-matrix) for separate CLI
and component observations and explicit #13/#25/#31/#32/#37 gaps. These checks
do not establish real-model quality, new result validation or atomic writes.

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
unused and never automatically removed. For an inconsistent cache, reproduce
with a new private cache/prefix rather than deleting reusable state:

```bash
scratch="$(mktemp -d)"
zig build --cache-dir "$scratch/cache" --prefix "$scratch/install"
```

A probe type error requires checking the pinned API against the adapter, not
disabling compiler errors. Empty/mismatched count summaries fail the stage;
inspect raw runner logs and the known profile-specific skip. Invalid stage
arguments exit 2. Command failures stay nonzero, including the benchmark
sensitivity check:

```bash
KOTOBA_BENCH_EXPECT_MISMATCH=1 bash test/ci/linux.sh integration
# nonzero: benchmark validation failed: direct translated text mismatch
```

CUDA remains optional:

```bash
env -u KOTOBA_CUDA_MODEL bash test/integration/cuda_smoke.sh
# SKIP cuda qa: missing KOTOBA_CUDA_MODEL or nvidia-smi
```

That successful skip is not CUDA coverage. Use `-Dcuda=true` and a real model
only for explicit manual QA; requested CUDA builds fail if the toolkit or its
libraries are unavailable.
