# PROJECT KNOWLEDGE BASE

## OVERVIEW
`test/integration/` drives copied `kotoba` binaries through private fixtures: smoke, CLI contracts, benchmark, build contracts, repeated parallel runs, and guarded CUDA QA.

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Fixture lifecycle and snapshots | `common.sh` | Private HOME/XDG, build lock, cleanup, `--self-test`. |
| Main end-to-end smoke | `smoke.sh` | Deterministic backend, loopback network observer, nested benchmark. |
| Full CLI matrix | `cli_matrix.sh`, `matrix_common.sh` | Per-case argv, streams, exit status, filesystem/DB observations, receipts. |
| Matrix cases | `matrix_translate.sh`, `matrix_commands.sh`, `matrix_memory.sh`, `matrix_files.sh` | Sourced case groups, not standalone scripts. |
| Deterministic benchmark | `bench.sh` | Emits JSON and validates expected translations. |
| Concurrency and repeated runs | `parallel.sh` | Separate unit/smoke/bench/matrix processes; configurable rounds. |
| Build regressions | `build_contract.sh` | Pin, API probe, copied unit runner, cache, missing-tool cases. |
| Model URL privacy | `secret_urls.sh` | Real CLI rejection, redaction and registry migration checks. |
| CUDA QA | `cuda_smoke.sh` | Skips unless `KOTOBA_CUDA_MODEL` and `nvidia-smi` exist. |
| CI orchestration | `../ci/linux.sh`, `../../docs/ci.md` | Integration stage: harness self-test, smoke, full matrix, two parallel rounds. |

## CONVENTIONS
- Executable suites use `set -euo pipefail`; `harness_init` supplies private HOME/XDG dirs, never the developer's real config.
- The shared build helper sets `ZIG_GLOBAL_CACHE_DIR="${ROOT}/.zig-cache/global"`; do not duplicate its build plumbing in case helpers.
- Use the deterministic test backend for normal smoke/bench checks.
- Executable suite entrypoints source `common.sh` and call `harness_init <suite>`; sourced case helpers share their caller's state.
- Keep stdout, stderr, PTY, benchmark JSON, model fixtures, and other captures
  under that run's private `TMP`; never use a fixed shared `/tmp` path or
  remove a path the current run did not create.
- Use `harness_build_snapshot` so build coordination covers artifact creation
  and copying, then releases before binary execution or nested benchmarks.
- Snapshots invoke `zig build test-artifacts` with a private prefix, then copy `kotoba` and `kotoba-tests` to `BIN` and `UNIT_BIN`. Profiles are `test`, `cpu`, and `cuda`.
- Preserve evidence outside the run's temporary root using supported evidence options; CI's `KOTOBA_CI_EVIDENCE_DIR` must be absolute.
- A passing matrix requires nonempty selected groups and passing per-case receipts, not just exit status. Preserve cleanup records and measured test/skip counts.
- CUDA checks must be optional and skip successfully on non-CUDA machines.
- Global llama/log state tests remain serial within a unit-test process;
  separate harness processes are the supported concurrency boundary.

## ANTI-PATTERNS
- Do not leave temp dirs, generated benchmark JSON, or spawned processes behind.
- Do not weaken smoke assertions around removed server config keys, no-curl runtime source, or quiet stdout.
- Do not edit tracked files during CI stages: before/after source and submodule status snapshots must match, even when pre-existing dirt is allowed.
- Do not treat CUDA skips, injected downloader success, or pre-call filesystem faults as real GPU, HTTPS-transfer, or mid-write atomicity coverage.
