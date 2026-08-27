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
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if [[ -n "$CHILD_PID" ]]; then
    kill -TERM -- "-$CHILD_PID" 2>/dev/null
    wait "$CHILD_PID" 2>/dev/null
  fi
  rm -rf -- "$OWNED"
  if [[ -e "$OWNED" ]]; then status=1; fi
  git status --short >"$EVIDENCE/source.after"
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
git status --short >"$EVIDENCE/source.before"
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
  python3 - "$EVIDENCE/$1.stderr" "$1" >>"$EVIDENCE/counts.tsv" <<'PY'
import pathlib, re, sys
matches = re.findall(r'(\d+)/(\d+) tests passed', pathlib.Path(sys.argv[1]).read_text())
assert len(matches) == 1 and int(matches[0][0]) > 0 and matches[0][0] == matches[0][1], matches
print(f'{sys.argv[2]}\t{matches[0][0]}')
PY
}
case "$STAGE" in
  format)
    run zig-format zig fmt --check build.zig src
    run git-diff git diff --check
    ;;
  build)
    run production-build zig build
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
    unit_count production-unit
    run deterministic-unit zig build test -Dtest-backend=true --summary all
    unit_count deterministic-unit
    ;;
  integration)
    run common bash test/integration/common.sh --self-test
    run smoke bash test/integration/smoke.sh
    run parallel bash test/integration/parallel.sh --rounds 2 --evidence-dir "$EVIDENCE/parallel"
    python3 - "$EVIDENCE" >>"$EVIDENCE/counts.tsv" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
assert 'harness self-test ok' in (root / 'common.stdout').read_text()
assert 'smoke ok' in (root / 'smoke.stdout').read_text()
runs = list((root / 'parallel').glob('parallel.*'))
assert len(runs) == 1, runs
run = runs[0]
statuses = list(run.glob('round-*.status'))
assert len(statuses) == 14 and all(re.search(r' status=0\n?$', p.read_text()) for p in statuses)
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
