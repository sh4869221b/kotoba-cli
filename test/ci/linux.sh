#!/usr/bin/env bash
set -euo pipefail

invalid() { echo 'linux ci: invalid stage' >&2; exit 2; }
[[ "$#" == 1 ]] || invalid
STAGE="$1"
case "$STAGE" in format|build|unit|integration) ;; *) invalid ;; esac
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
  git status --porcelain=v1 --untracked-files=all --ignore-submodules=none >"$EVIDENCE/source.$1" &&
    git -C vendor/llama.cpp status --porcelain=v1 --untracked-files=all >"$EVIDENCE/vendor.$1"
}
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if [[ -n "$CHILD_PID" ]]; then
    kill -TERM -- "-$CHILD_PID" 2>/dev/null
    wait "$CHILD_PID" 2>/dev/null
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
  printf 'stage=%s\nexit=%s\nowned=%s\nowned_removed=%s\n' "$STAGE" "$status" "$OWNED" "$([[ ! -e "$OWNED" ]] && echo yes || echo no)" >"$EVIDENCE/status.txt"
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
if ! snapshot before; then echo 'linux ci: cannot read source status' >&2; exit 1; fi
{ git rev-parse HEAD; git ls-tree HEAD vendor/llama.cpp; git -C vendor/llama.cpp rev-parse HEAD; zig version; cc --version; cmake --version; } >"$EVIDENCE/identity.txt"
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
    run clang-production-build env CC=clang CXX=clang++ zig build --cache-dir "$OWNED/clang-cache" --prefix "$OWNED/clang-prefix"
    cp "$OWNED/clang-cache/llama.cpp/cpu/CMakeCache.txt" "$EVIDENCE/clang-CMakeCache.txt"
    grep -Eq '^CMAKE_CXX_COMPILER:(FILEPATH|STRING)=.*/clang\+\+(-[0-9]+)?$' "$EVIDENCE/clang-CMakeCache.txt"
    run clang-cli-version "$OWNED/clang-prefix/bin/kotoba" version
    cmp "$EVIDENCE/production-cli-version.stdout" "$EVIDENCE/clang-cli-version.stdout"
    run clang-linkage ldd "$OWNED/clang-prefix/bin/kotoba"
    sha256sum "$ROOT/zig-out/bin/kotoba" "$OWNED/clang-prefix/bin/kotoba" >"$EVIDENCE/binaries.sha256"
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
    run smoke bash test/integration/smoke.sh
    run cli-matrix bash test/integration/cli_matrix.sh --evidence-dir "$EVIDENCE/cli-matrix"
    run parallel bash test/integration/parallel.sh --rounds 2 --evidence-dir "$EVIDENCE/parallel"
    python3 - "$EVIDENCE" >>"$EVIDENCE/counts.tsv" <<'PY'
import collections, json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
assert 'harness self-test ok' in (root / 'common.stdout').read_text()
assert 'smoke ok' in (root / 'smoke.stdout').read_text()
matrices = list((root / 'cli-matrix').glob('cli-matrix.*'))
assert len(matrices) == 1, matrices
matrix = matrices[0]
summary = json.loads((matrix / 'summary.json').read_text())
receipts = [json.loads(path.read_text()) for path in (matrix / 'cases').glob('*/receipt.json')]
counts = collections.Counter(receipt['group'] for receipt in receipts)
assert set(counts) == {'translate', 'commands', 'memory', 'files'} and all(counts.values()), counts
assert dict(counts) == summary['groups'] and len(receipts) == summary['passed'] > 0
assert len(set(summary['cases'])) == len(receipts) and set(summary['cases']) == {r['case_id'] for r in receipts}
for receipt in receipts:
    assert receipt['level'] == 'cli' and receipt['verdict'] == 'pass' and not receipt['harness_timeout']
    assert receipt['assertions'] and all(check['passed'] for check in receipt['assertions'])
    case = matrix / 'cases' / receipt['case_id']
    assert int((case / 'status').read_text()) == receipt['status']
    for artifact in ('stdout', 'stderr', 'fs_before', 'fs_after', 'db_before', 'db_after'):
        assert (case / receipt[artifact]).is_file(), (case, artifact)
cleanup = json.loads((matrix / 'cleanup.json').read_text())
assert cleanup['exit_status'] == 0 and cleanup['temporary_removed'] and cleanup['lock_released']
for group, count in sorted(counts.items()):
    print(f'cli-matrix-{group}\t{count}')
print(f'cli-matrix-total\t{len(receipts)}')
runs = list((root / 'parallel').glob('parallel.*'))
assert len(runs) == 1, runs
run = runs[0]
statuses = list(run.glob('round-*.status'))
assert len(statuses) == 18 and all(re.search(r' status=0\n?$', p.read_text()) for p in statuses)
unit_total = 0
for path in run.glob('round-*-unit-*.err'):
    match = re.search(r'All (\d+) tests passed\.', path.read_text())
    assert match and int(match[1]) > 0, path
    unit_total += int(match[1])
assert len(list(run.glob('round-*-unit-*.err'))) == 8
benchmarks = list(run.glob('round-*-bench.out'))
assert len(benchmarks) == 2
measurements = 0
for path in benchmarks:
    payload = json.loads(path.read_text())
    assert payload['iterations'] == 5 and len(payload['inputs']) == 3
    measurements += payload['iterations'] * len(payload['inputs'])
print(f'common\t1\nsmoke\t1\nparallel-children\t{len(statuses)}\nparallel-unit-tests\t{unit_total}\nparallel-benchmark-measurements\t{measurements}')
PY
    ;;
esac
