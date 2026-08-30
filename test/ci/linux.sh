#!/usr/bin/env bash
set -euo pipefail

invalid_stage() { echo 'linux ci: invalid stage' >&2; exit 2; }
invalid_integration() { echo 'linux ci: invalid integration arguments' >&2; exit 2; }
[[ "$#" -ge 1 ]] || invalid_stage
STAGE="$1"
shift
case "$STAGE" in format|build|unit|integration) ;; *) invalid_stage ;; esac
SUITE=all
SUITE_EXPLICIT=0
ROUNDS=2
ROUNDS_EXPLICIT=0
if [[ "$STAGE" == integration ]]; then
  while (($#)); do
    (($# >= 2)) || invalid_integration
    case "$1" in
      --suite)
        [[ "$SUITE_EXPLICIT" == 0 ]] || invalid_integration
        SUITE="$2"
        SUITE_EXPLICIT=1
        ;;
      --rounds)
        [[ "$ROUNDS_EXPLICIT" == 0 && "$2" =~ ^[1-9][0-9]{0,3}$ ]] || invalid_integration
        ROUNDS="$2"
        ROUNDS_EXPLICIT=1
        (( ROUNDS <= 1000 )) || invalid_integration
        ;;
      *) invalid_integration ;;
    esac
    shift 2
  done
  case "$SUITE" in all|smoke|matrix|parallel) ;; *) invalid_integration ;; esac
  [[ "$ROUNDS_EXPLICIT" == 0 || "$SUITE" == all || "$SUITE" == parallel ]] || invalid_integration
else
  [[ "$#" == 0 ]] || invalid_stage
fi
PARALLEL_CHILDREN=0
PARALLEL_UNIT_LOGS=0
PARALLEL_BENCHMARKS=0
PARALLEL_MEASUREMENTS=0
if [[ "$SUITE" == all || "$SUITE" == parallel ]]; then
  PARALLEL_CHILDREN=$((9 * ROUNDS))
  PARALLEL_UNIT_LOGS=$((4 * ROUNDS))
  PARALLEL_BENCHMARKS="$ROUNDS"
  PARALLEL_MEASUREMENTS=$((15 * ROUNDS))
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
if [[ -n "${KOTOBA_CI_EVIDENCE_DIR:-}" ]]; then
  [[ "$KOTOBA_CI_EVIDENCE_DIR" == /* ]] || { echo 'linux ci: evidence directory must be absolute' >&2; exit 2; }
  mkdir -p "$KOTOBA_CI_EVIDENCE_DIR"
else
  KOTOBA_CI_EVIDENCE_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kotoba-ci-evidence.XXXXXX")"
fi
export KOTOBA_CI_EVIDENCE_DIR
EVIDENCE="$KOTOBA_CI_EVIDENCE_DIR"
OWNED="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kotoba-ci-${STAGE}.XXXXXX")"
CHILD_PID=""
snapshot() {
  git status --porcelain=v1 --untracked-files=all --ignore-submodules=none >"$EVIDENCE/source.$1" || return
  if [[ "$STAGE" == format ]]; then
    printf 'not-required\n' >"$EVIDENCE/vendor.$1"
  else
    git -C vendor/llama.cpp status --porcelain=v1 --untracked-files=all >"$EVIDENCE/vendor.$1"
  fi
}
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if [[ -n "$CHILD_PID" ]]; then
    kill -TERM -- "-$CHILD_PID" 2>/dev/null
    wait "$CHILD_PID" 2>/dev/null
  fi
  if [[ "${KOTOBA_CI_NATIVE_CACHE:-0}" == 1 && "$STAGE" != format ]]; then
    for family in gcc clang; do
      local directory="${KOTOBA_CCACHE_GCC_DIR:-}"
      [[ "$family" == gcc ]] || directory="${KOTOBA_CCACHE_CLANG_DIR:-}"
      [[ -n "$directory" && -d "$directory" ]] || continue
      if ! CCACHE_DIR="$directory" ccache --show-stats >"$EVIDENCE/ccache-$family.after" 2>&1; then
        [[ "$status" != 0 ]] || status=1
      fi
    done
  fi
  rm -rf -- "$OWNED"
  if [[ -e "$OWNED" && "$status" == 0 ]]; then status=1; fi
  if ! snapshot after; then
    echo 'linux ci: cannot read source status' >&2
    [[ "$status" != 0 ]] || status=1
  elif ! cmp -s "$EVIDENCE/source.before" "$EVIDENCE/source.after" || ! cmp -s "$EVIDENCE/vendor.before" "$EVIDENCE/vendor.after"; then
    echo 'linux ci: source status changed' >&2
    [[ "$status" != 0 ]] || status=1
  fi
  {
    printf 'stage=%s\nexit=%s\nowned=%s\nowned_removed=%s\n' "$STAGE" "$status" "$OWNED" "$([[ ! -e "$OWNED" ]] && echo yes || echo no)"
    if [[ "$STAGE" == integration ]]; then
      printf 'suite=%s\nrounds=%s\nparallel_children=%s\nparallel_unit_logs=%s\nparallel_benchmarks=%s\nparallel_benchmark_measurements=%s\n' \
        "$SUITE" "$ROUNDS" "$PARALLEL_CHILDREN" "$PARALLEL_UNIT_LOGS" "$PARALLEL_BENCHMARKS" "$PARALLEL_MEASUREMENTS"
    fi
  } >"$EVIDENCE/status.txt"
  cat "$EVIDENCE/status.txt"
  [[ ! -f "$EVIDENCE/counts.tsv" ]] || cat "$EVIDENCE/counts.tsv"
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || cat "$EVIDENCE/identity.txt" "$EVIDENCE/status.txt" "$EVIDENCE/counts.tsv" >>"$GITHUB_STEP_SUMMARY"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$OWNED/home" XDG_CONFIG_HOME="$OWNED/config" XDG_DATA_HOME="$OWNED/data"
export XDG_CACHE_HOME="$OWNED/cache" XDG_STATE_HOME="$OWNED/state" TMPDIR="$OWNED/tmp"
export ZIG_GLOBAL_CACHE_DIR="$ROOT/.zig-cache/global"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$TMPDIR"
: >"$EVIDENCE/counts.tsv"
if [[ "$STAGE" != format ]]; then
  vendor_root="$(git -C vendor/llama.cpp rev-parse --show-toplevel 2>/dev/null || :)"
  if [[ "$vendor_root" != "$ROOT/vendor/llama.cpp" ]]; then
    echo 'llama.cpp submodule is not initialized; run git submodule update --init --recursive' >&2
    exit 1
  fi
fi
if ! snapshot before; then echo 'linux ci: cannot read source status' >&2; exit 1; fi
if [[ "$STAGE" == format ]]; then
  { git rev-parse HEAD; printf 'vendor=not-required\n'; zig version; } >"$EVIDENCE/identity.txt"
else
  { git rev-parse HEAD; git ls-tree HEAD vendor/llama.cpp; git -C vendor/llama.cpp rev-parse HEAD; zig version; cc --version; cmake --version; } >"$EVIDENCE/identity.txt"
fi
cat "$EVIDENCE/identity.txt"
run() {
  local label="$1" status; shift
  { printf 'cwd=%q\nargv=' "$PWD"; printf '%q ' "$@"; printf '\n'; } >"$EVIDENCE/$label.command"
  local restore_job_control=0
  case "$-" in *m*) ;; *) set -m; restore_job_control=1 ;; esac
  "$@" >"$EVIDENCE/$label.stdout" 2>"$EVIDENCE/$label.stderr" &
  CHILD_PID=$!
  if [[ "$restore_job_control" == 1 ]]; then set +m; fi
  if wait "$CHILD_PID"; then status=0; else status=$?; fi
  CHILD_PID=""
  printf '%s\n' "$status" >"$EVIDENCE/$label.status"
  cat "$EVIDENCE/$label.stdout"
  cat "$EVIDENCE/$label.stderr" >&2
  return "$status"
}
unit_count() {
  python3 - "$EVIDENCE/$1.stderr" "$1" "$2" >>"$EVIDENCE/counts.tsv" <<'PY'
import pathlib, re, sys
matches = re.findall(r'^Build Summary: [^\n]*; (\d+)/(\d+) tests passed(?: \((\d+) skipped\))?$', pathlib.Path(sys.argv[1]).read_text(), re.M)
assert len(matches) == 1, matches
passed, total, skipped = (int(value or 0) for value in matches[0])
assert passed > 0 and skipped == int(sys.argv[3]) and passed + skipped == total, matches
print(f'{sys.argv[2]}\t{passed}\n{sys.argv[2]}-skipped\t{skipped}\n{sys.argv[2]}-failed\t0')
PY
}
cache_prepare() {
  local family="$1" directory="$ROOT/.zig-cache"
  export CC=gcc CXX=g++ CCACHE_DIR="$KOTOBA_CCACHE_GCC_DIR"
  if [[ "$family" == clang ]]; then
    directory="$ROOT/.zig-cache/ci-clang"
    export CC=clang CXX=clang++ CCACHE_DIR="$KOTOBA_CCACHE_CLANG_DIR"
  fi
  run "native-$family-identity" bash test/ci/native-cache.sh identity --compiler "$family" --output "$EVIDENCE/native-$family.json"
  run "native-$family-validate" bash test/ci/native-cache.sh validate --compiler "$family" --cache-dir "$directory" --identity "$EVIDENCE/native-$family.json"
}
cache_stamp() {
  local family="$1" directory="$ROOT/.zig-cache"
  [[ "$family" == gcc ]] || directory="$ROOT/.zig-cache/ci-clang"
  run "native-$family-stamp" bash test/ci/native-cache.sh stamp --compiler "$family" --cache-dir "$directory" --identity "$EVIDENCE/native-$family.json"
  cp "$directory/llama.cpp/cpu/CMakeCache.txt" "$EVIDENCE/native-$family-CMakeCache.txt"
}
if [[ "${KOTOBA_CI_NATIVE_CACHE:-0}" == 1 && "$STAGE" != format ]]; then
  export KOTOBA_CCACHE_GCC_DIR="${KOTOBA_CCACHE_GCC_DIR:-${RUNNER_TEMP:-$ROOT/.zig-cache}/kotoba-ccache/gcc}"
  export KOTOBA_CCACHE_CLANG_DIR="${KOTOBA_CCACHE_CLANG_DIR:-${RUNNER_TEMP:-$ROOT/.zig-cache}/kotoba-ccache/clang}"
  for directory in "$KOTOBA_CCACHE_GCC_DIR" "$KOTOBA_CCACHE_CLANG_DIR"; do
    [[ "$directory" == /* && "$directory" != "$OWNED"/* ]] || { echo 'linux ci cache: invalid compiler cache directory' >&2; exit 2; }
    mkdir -p "$directory"
  done
  gcc_directory="$(realpath "$KOTOBA_CCACHE_GCC_DIR")"
  clang_directory="$(realpath "$KOTOBA_CCACHE_CLANG_DIR")"
  if [[ "$gcc_directory" == "$clang_directory" || "$gcc_directory" == "$clang_directory"/* || "$clang_directory" == "$gcc_directory"/* ]]; then
    echo 'linux ci cache: compiler cache directories overlap' >&2
    exit 2
  fi
  export CCACHE_COMPILERCHECK=content CCACHE_CONFIGPATH=/dev/null CCACHE_SLOPPINESS="" CCACHE_HASHDIR=true
  CMAKE_C_COMPILER_LAUNCHER="$(command -v ccache)"
  CMAKE_CXX_COMPILER_LAUNCHER="$CMAKE_C_COMPILER_LAUNCHER"
  export CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER
  for family in gcc clang; do
    directory="$KOTOBA_CCACHE_GCC_DIR"
    [[ "$family" == gcc ]] || directory="$KOTOBA_CCACHE_CLANG_DIR"
    CCACHE_DIR="$directory" ccache --show-stats >"$EVIDENCE/ccache-$family.before"
  done
  cache_prepare gcc
fi
case "$STAGE" in
  format)
    run zig-format zig fmt --check build.zig src
    run git-diff git diff --check
    ;;
  build)
    run production-build zig build
    run production-cli-version "$ROOT/zig-out/bin/kotoba" version
    run production-compiler c++ --version
    cp "$ROOT/.zig-cache/llama.cpp/cpu/CMakeCache.txt" "$EVIDENCE/production-CMakeCache.txt"
    run clang-compiler clang++ --version
    run clang-runtime clang++ -### -x c++ /dev/null -o /dev/null
    CLANG_CACHE="$OWNED/clang-cache"
    if [[ "${KOTOBA_CI_NATIVE_CACHE:-0}" == 1 ]]; then
      CLANG_CACHE="$ROOT/.zig-cache/ci-clang"
      cache_prepare clang
    fi
    run clang-production-build env CC=clang CXX=clang++ zig build --cache-dir "$CLANG_CACHE" --prefix "$OWNED/clang-prefix"
    cp "$CLANG_CACHE/llama.cpp/cpu/CMakeCache.txt" "$EVIDENCE/clang-CMakeCache.txt"
    grep -Eq '^CMAKE_CXX_COMPILER:(FILEPATH|STRING)=.*/clang\+\+(-[0-9]+)?$' "$EVIDENCE/clang-CMakeCache.txt"
    run clang-cli-version "$OWNED/clang-prefix/bin/kotoba" version
    cmp "$EVIDENCE/production-cli-version.stdout" "$EVIDENCE/clang-cli-version.stdout"
    run clang-linkage ldd "$OWNED/clang-prefix/bin/kotoba"
    sha256sum "$ROOT/zig-out/bin/kotoba" "$OWNED/clang-prefix/bin/kotoba" >"$EVIDENCE/binaries.sha256"
    if [[ "${KOTOBA_CI_NATIVE_CACHE:-0}" == 1 ]]; then
      cache_stamp clang
      export CC=gcc CXX=g++ CCACHE_DIR="$KOTOBA_CCACHE_GCC_DIR"
    fi
    run build-contract bash test/integration/build_contract.sh --case all --evidence-dir "$EVIDENCE/build-contract"
    python3 - "$EVIDENCE/build-contract/assertions.tsv" >>"$EVIDENCE/counts.tsv" <<'PY'
import collections, pathlib, sys
counts = collections.Counter()
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    case, status, _ = line.split('\t', 2)
    assert status == 'PASS'
    counts[case] += 1
assert set(counts) == {'pin', 'probe', 'runner', 'cache', 'tools'}
for case, count in counts.items():
    print(f'build-contract-{case}\t{count}')
PY
    ;;
  unit)
    run production-unit zig build test --summary all
    unit_count production-unit 1
    run deterministic-unit zig build test -Dtest-backend=true --summary all
    unit_count deterministic-unit 0
    ;;
  integration)
    run common bash test/integration/common.sh --self-test
    if [[ "$SUITE" == all || "$SUITE" == smoke ]]; then run smoke bash test/integration/smoke.sh; fi
    if [[ "$SUITE" == all || "$SUITE" == matrix ]]; then run cli-matrix bash test/integration/cli_matrix.sh --evidence-dir "$EVIDENCE/cli-matrix"; fi
    if [[ "$SUITE" == all || "$SUITE" == parallel ]]; then
      if run parallel bash test/integration/parallel.sh --rounds "$ROUNDS" --evidence-dir "$EVIDENCE/parallel"; then
        :
      else
        parallel_status=$?
        find "$EVIDENCE/parallel" -name 'round-*-bench.err' -type f -exec cat {} \; >&2
        exit "$parallel_status"
      fi
    fi
    run integration-evidence python3 test/ci/integration-evidence.py --suite "$SUITE" --rounds "$ROUNDS" --evidence-dir "$EVIDENCE"
    cat "$EVIDENCE/integration-evidence.stdout" >>"$EVIDENCE/counts.tsv"
    ;;
esac

if [[ "${KOTOBA_CI_NATIVE_CACHE:-0}" == 1 && "$STAGE" != format ]]; then cache_stamp gcc; fi
