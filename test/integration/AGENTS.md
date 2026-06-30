# PROJECT KNOWLEDGE BASE

## OVERVIEW
`test/integration/` contains shell-driven surface checks for the built `kotoba` binary: deterministic smoke coverage, benchmark JSON output, and guarded CUDA QA.

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| Main end-to-end smoke | `smoke.sh` | Builds with `-Dtest-backend=true`, isolated XDG dirs. |
| Deterministic benchmark | `bench.sh` | Emits JSON and validates expected translations. |
| CUDA QA | `cuda_smoke.sh` | Skips unless `KOTOBA_CUDA_MODEL` and `nvidia-smi` exist. |

## CONVENTIONS
- Scripts use `set -euo pipefail` and temp XDG dirs; do not touch the developer's real config.
- Build with `env ZIG_GLOBAL_CACHE_DIR="${ROOT}/.zig-cache/global"` to keep Zig cache predictable.
- Use the deterministic test backend for normal smoke/bench checks.
- Assert stdout/stderr contracts with files under `/tmp` or script temp dirs.
- CUDA checks must be optional and skip successfully on non-CUDA machines.

## ANTI-PATTERNS
- Do not require real network, real GGUF models, CUDA hardware, or an installed `curl` for default integration checks.
- Do not leave temp dirs, generated benchmark JSON, or spawned processes behind.
- Do not weaken smoke assertions around removed server config keys, no-curl runtime source, or quiet stdout.
- Do not use the user's persistent XDG paths.
