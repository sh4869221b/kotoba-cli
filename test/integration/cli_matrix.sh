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
  local positive="$CASE_DIR" negative rc name
  matrix_case helper-journal-noop helper
  mkdir -p "$(dirname "$CASE_DB")"
  python3 - "$CASE_DB" <<'PY'
from contextlib import closing
from pathlib import Path
import sqlite3
import sys

database = Path(sys.argv[1])
with closing(sqlite3.connect(database)) as connection:
    connection.execute("CREATE TABLE translations (value TEXT NOT NULL)")
    connection.execute("INSERT INTO translations VALUES ('seeded-before-capture')")
    connection.commit()
Path(str(database) + "-journal").touch()
PY
  matrix_run -c ':'
  matrix_assert status 0
  matrix_assert fs-equal
  matrix_assert db-equal
  matrix_assert custom journal-observer python3 - "$CASE_DIR" <<'PY'
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1])
state = json.loads((directory / "db-before.json").read_text())
assert state == {"status": "readable", "columns": ["value"], "rows": [["seeded-before-capture"]], "row_count": 1}
before = {entry["path"]: entry for entry in json.loads((directory / "fs-before.json").read_text())}
assert before["data/kotoba/memory.sqlite3-journal"]["sha256"] == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
print('{"observer":"readonly-logical-snapshot","journal":"unchanged"}')
PY
  matrix_finish
  matrix_case helper-wal-noop helper
  mkdir -p "$(dirname "$CASE_DB")"
  python3 - "$CASE_DB" <<'PY'
from contextlib import closing
from pathlib import Path
import sqlite3
import sys

database = Path(sys.argv[1])
with closing(sqlite3.connect(database)) as connection:
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("CREATE TABLE translations (value TEXT NOT NULL)")
    connection.execute("INSERT INTO translations VALUES ('seeded-before-capture')")
    connection.commit()
for suffix, contents in (("-wal", b"stopped WAL sidecar\\n"), ("-shm", b"stopped SHM sidecar\\n")):
    Path(str(database) + suffix).write_bytes(contents)
PY
  matrix_run -c ':'
  matrix_assert status 0
  matrix_assert fs-equal
  matrix_assert db-equal
  matrix_assert custom wal-observer python3 - "$CASE_DIR" <<'PY'
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1])
for phase in ("before", "after"):
    state = json.loads((directory / f"db-{phase}.json").read_text())
    assert state == {"status": "skipped_unsafe", "reason": ["wal_header", "-wal", "-shm"], "sqlite_opened": False}
print('{"observer":"skipped_unsafe","sqlite_opened":false}')
PY
  matrix_finish
  matrix_case helper-wal-sidecar-mutation helper
  mkdir -p "$(dirname "$CASE_DB")"
  python3 - "$CASE_DB" <<'PY'
from contextlib import closing
from pathlib import Path
import sqlite3
import sys

database = Path(sys.argv[1])
with closing(sqlite3.connect(database)) as connection:
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("CREATE TABLE translations (value TEXT NOT NULL)")
    connection.execute("INSERT INTO translations VALUES ('seeded-before-capture')")
    connection.commit()
for suffix, contents in (("-wal", b"stopped WAL sidecar\\n"), ("-shm", b"stopped SHM sidecar\\n")):
    Path(str(database) + suffix).write_bytes(contents)
PY
  matrix_run -c 'printf mutation > "$1-wal"' bash "$CASE_DB"
  matrix_assert status 0
  rc=0
  matrix_python check fs-equal >"$CASE_DIR/wal-sidecar-rejection.stdout" 2>"$CASE_DIR/wal-sidecar-rejection.stderr" || rc=$?
  printf '%s\n' "$rc" >"$CASE_DIR/wal-sidecar-rejection.status"
  [[ "$rc" != 0 ]] || { echo 'cli matrix: self-test accepted WAL sidecar mutation' >&2; return 1; }
  matrix_python verdict 0 wal-sidecar-mutation-rejected
  matrix_assert db-equal
  matrix_finish
  negative="$MATRIX_CAPTURE/rejections"
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
wal_noop = root / "cases/helper-wal-noop"
wal_mutation = root / "cases/helper-wal-sidecar-mutation"
assert json.loads((wal_noop / "db-before.json").read_text())["sqlite_opened"] is False
assert json.loads((wal_noop / "db-before.json").read_text()) == json.loads((wal_noop / "db-after.json").read_text())
assert int((wal_mutation / "wal-sidecar-rejection.status").read_text()) != 0
assert (wal_mutation / "fs-before.json").read_bytes() != (wal_mutation / "fs-after.json").read_bytes()
(root / "self-test.json").write_text(json.dumps({"level": "helper", "rejected": rejections, "absent_db_stayed_absent": True,
                                               "positive_captures": 9, "product_coverage": False,
                                               "wal_observer": "skipped unsafe WAL/header/sidecar without SQLite open",
                                               "wal_sidecar_mutation_rejected": True}) + "\n")
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
