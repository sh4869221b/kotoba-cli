#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

matrix_cleanup() {
  local status=$? original_tmp="${TMP}"
  trap - EXIT INT TERM
  if [[ -n "${MATRIX_CAPTURE_PID:-}" ]]; then
    kill -"${MATRIX_STOP_SIGNAL:-TERM}" "$MATRIX_CAPTURE_PID" 2>/dev/null || true
    wait "$MATRIX_CAPTURE_PID" 2>/dev/null || true
  fi
  if [[ -n "${MATRIX_SETUP_PID:-}" ]]; then
    kill -"${MATRIX_STOP_SIGNAL:-TERM}" -- "-$MATRIX_SETUP_PID" 2>/dev/null || true
    wait "$MATRIX_SETUP_PID" 2>/dev/null || true
  fi
  harness_stop_build
  cp -R "$MATRIX_CAPTURE/." "$MATRIX_EVIDENCE/" || status=1
  cd "$ROOT"
  harness_cleanup || status=1
  python3 - "$MATRIX_EVIDENCE/cleanup.json" "$original_tmp" "$HARNESS_LOCK_OWNED" "$status" <<'PY'
import json
from pathlib import Path
import sys
path, temporary, lock_owned, status = sys.argv[1:]
receipt = {"temporary_root": temporary, "temporary_removed": not Path(temporary).exists(),
           "lock_released": lock_owned == "0", "exit_status": int(status)}
Path(path).write_text(json.dumps(receipt) + "\n")
assert receipt["temporary_removed"] and receipt["lock_released"], "cli matrix: cleanup incomplete"
PY
  exit "$status"
}

matrix_summary() {
  python3 - "$MATRIX_CAPTURE" "$MATRIX_SELF_TEST" "$1" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
cases = sorted((root / "cases").iterdir()) if (root / "cases").exists() else []
assert cases, "cli matrix: zero selected cases"
receipts = [json.loads((case / "receipt.json").read_text()) for case in cases]
assert all(receipt["verdict"] == "pass" for receipt in receipts), "cli matrix: unfinished case"
groups = ["helper"] if sys.argv[2] == "1" else (["translate", "commands", "memory", "files"] if sys.argv[3] == "all" else [sys.argv[3]])
counts = {group: sum(receipt["group"] == group for receipt in receipts) for group in groups}
assert all(counts.values()), "cli matrix: selected group has zero cases"
(root / "summary.json").write_text(json.dumps({"passed": len(receipts), "groups": counts, "cases": [r["case_id"] for r in receipts]}) + "\n")
PY
}

matrix_self_test() {
  matrix_case helper-positive helper
  printf 'hello "quoted" \\ path\n' >"$CASE_DIR/expected.stdout"
  : >"$CASE_DIR/empty"
  matrix_run -c 'printf "%s\n" "$1"' bash 'hello "quoted" \ path'
  matrix_assert status 0
  matrix_assert stdout "$CASE_DIR/expected.stdout"
  matrix_assert stderr "$CASE_DIR/empty"
  matrix_assert fs-equal
  matrix_assert db-equal
  matrix_finish
  [[ ! -e "$CASE_DB" ]]
  local positive="$CASE_DIR" negative="$MATRIX_CAPTURE/rejections" rc name
  mkdir -p "$negative"
  for name in status stdout stderr state malformed-json missing-key extra-key bool-integer; do
    CASE_DIR="$negative/$name"
    mkdir "$CASE_DIR"
    cp "$positive/"* "$CASE_DIR/"
    case "$name" in
      status) set -- status 7 ;;
      stdout) set -- stdout "$positive/empty" ;;
      stderr) set -- stderr "$positive/expected.stdout" ;;
      state) printf '[]\n' >"$CASE_DIR/fs-after.json"; set -- fs-equal ;;
      malformed-json) printf '{' >"$CASE_DIR/stdout"; set -- json success ;;
      *)
        python3 - "$CASE_DIR/stdout" "$name" <<'PY'
import json
from pathlib import Path
import sys
value = {"source_lang": "en", "target_lang": "ja", "mode": "default", "model_id": "m", "runtime": "embedded",
         "cached": False, "cache_status": "none", "cached_segments": 0, "total_segments": 1,
         "translated_text": "JA:Hello", "warnings": [], "elapsed_ms": 0}
match sys.argv[2]:
    case "missing-key":
        del value["runtime"]
    case "extra-key":
        value["extra"] = "unexpected"
    case "bool-integer":
        value["elapsed_ms"] = True
Path(sys.argv[1]).write_text(json.dumps(value))
PY
        set -- json success ;;
    esac
    rc=0
    matrix_python check "$@" >"$CASE_DIR/rejection.stdout" 2>"$CASE_DIR/rejection.stderr" || rc=$?
    printf '%s\n' "$rc" >"$CASE_DIR/rejection.status"
    [[ "$rc" != 0 ]] || { echo "cli matrix: self-test accepted $name" >&2; return 1; }
  done
  CASE_DIR="$positive"
  rc=0
  matrix_case helper-positive helper >"$negative/duplicate.stdout" 2>"$negative/duplicate.stderr" || rc=$?
  printf '%s\n' "$rc" >"$negative/duplicate.status"
  [[ "$rc" != 0 ]]
  matrix_case helper-nonzero helper
  matrix_run -c 'printf after > changed; printf failure >&2; exit 7'
  matrix_assert status 7
  printf failure >"$CASE_DIR/expected.stderr"
  printf after >"$CASE_DIR/expected.file"
  matrix_assert stderr "$CASE_DIR/expected.stderr"
  matrix_assert file "$CASE_ROOT/work/changed" "$CASE_DIR/expected.file"
  matrix_assert db-equal
  matrix_finish
  matrix_case helper-json helper
  matrix_run -c 'printf "%s\n" "$1"' bash '{"source_lang":"en","target_lang":"ja","mode":"default","model_id":"m","runtime":"embedded","cached":false,"cache_status":"none","cached_segments":0,"total_segments":1,"translated_text":"JA:Hello","warnings":[],"elapsed_ms":0}'
  matrix_assert status 0
  matrix_assert json success
  matrix_assert json-values '{"translated_text":"JA:Hello","cached_segments":0,"total_segments":1}'
  matrix_finish
  local kind payload
  for kind in error doctor success-source; do
    case "$kind" in
      error) payload='{"error":{"code":"invalid_arguments","message":"Invalid arguments."}}' ;;
      doctor) payload='{"ok":false,"checks":[{"name":"model","status":"fail","code":"missing","message":"Missing."}]}' ;;
      success-source) payload='{"source_lang":"en","target_lang":"ja","mode":"default","model_id":"m","runtime":"embedded","cached":true,"cache_status":"none","cached_segments":0,"total_segments":0,"translated_text":"","warnings":[],"elapsed_ms":0,"source_text":""}' ;;
    esac
    matrix_case "helper-json-$kind" helper
    matrix_run -c 'printf "%s\n" "$1"' bash "$payload"
    matrix_assert status 0
    matrix_assert json "$kind"
    matrix_finish
  done
  python3 - "$MATRIX_CAPTURE" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
rejections = {path.parent.name: int(path.read_text()) for path in (root / "rejections").glob("*/rejection.status")}
assert len(rejections) == 8 and all(rejections.values())
(root / "self-test.json").write_text(json.dumps({"level": "helper", "rejected": rejections, "absent_db_stayed_absent": True,
                                               "positive_captures": 6, "product_coverage": False}) + "\n")
PY
}

matrix_main() {
  local group="$1" evidence="$2"
  MATRIX_SELF_TEST="$3"
  source "$SCRIPT_DIR/common.sh"
  source "$SCRIPT_DIR/matrix_common.sh"
  harness_init cli-matrix
  MATRIX_CAPTURE="$TMP/captures"
  mkdir -p "$MATRIX_CAPTURE" "$evidence"
  MATRIX_EVIDENCE="$(mktemp -d "$evidence/cli-matrix.XXXXXX")"
  trap matrix_cleanup EXIT
  trap 'MATRIX_STOP_SIGNAL=INT; exit 130' INT
  trap 'MATRIX_STOP_SIGNAL=TERM; exit 143' TERM
  printf '%s\n' "$TMP" >"$MATRIX_CAPTURE/temporary-root"
  if [[ "$MATRIX_SELF_TEST" == 1 ]]; then
    export MATRIX_GROUP=helper
    matrix_self_test
  else
    local profile
    for profile in test cpu; do
      harness_build_snapshot "$profile" >"$MATRIX_CAPTURE/build-$profile.stdout" 2>"$MATRIX_CAPTURE/build-$profile.stderr"
      mkdir -p "$TMP/profiles/$profile"
      cp "$BIN" "$TMP/profiles/$profile/kotoba"
    done
    MATRIX_TEST_BIN="$TMP/profiles/test/kotoba"
    MATRIX_CPU_BIN="$TMP/profiles/cpu/kotoba"
    local selected
    for selected in translate commands memory files; do
      if [[ "$group" == all || "$group" == "$selected" ]]; then
        export MATRIX_GROUP="$selected"
        source "$SCRIPT_DIR/matrix_$selected.sh"
        "matrix_$selected"
      fi
    done
  fi
  matrix_summary "$group"
  printf 'cli matrix: passed; evidence: %s\n' "$MATRIX_EVIDENCE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  group=all evidence="${KOTOBA_ATTEMPT_DIR:-$SCRIPT_DIR/../../.omo/evidence}" self_test=0
  seen_group=0 seen_evidence=0
  invalid() { echo 'cli matrix: invalid arguments' >&2; exit 2; }
  while (( $# )); do
    case "$1" in
      --group) [[ $# -ge 2 && "$seen_group" == 0 ]] || invalid; group="$2"; seen_group=1; shift 2 ;;
      --evidence-dir) [[ $# -ge 2 && "$seen_evidence" == 0 && "$2" == /* ]] || invalid; evidence="$2"; seen_evidence=1; shift 2 ;;
      --self-test) [[ "$self_test" == 0 ]] || invalid; self_test=1; shift ;;
      *) invalid ;;
    esac
  done
  case "$group" in translate|commands|memory|files|all) ;; *) invalid ;; esac
  [[ "$evidence" == /* ]] || invalid
  if [[ "$self_test" == 0 ]]; then
    for selected in translate commands memory files; do
      if [[ "$group" == all || "$group" == "$selected" ]]; then
        [[ -f "$SCRIPT_DIR/matrix_$selected.sh" ]] || { echo "cli matrix: missing case file: matrix_$selected.sh" >&2; exit 1; }
      fi
    done
  fi
  exec timeout --foreground --kill-after=10s 1200s bash -c 'source "$1"; matrix_main "$2" "$3" "$4"' bash "$SCRIPT_DIR/cli_matrix.sh" "$group" "$evidence" "$self_test"
fi
