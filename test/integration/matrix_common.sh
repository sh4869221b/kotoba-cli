#!/usr/bin/env bash
set -euo pipefail

# Case API: case -> setup/fixture writes -> run -> assertions -> finish.
# CASE_ROOT is observed; CASE_DIR contains captures and independent expectations.
# A case runs exactly one measured command. Setup commands have separate captures.
matrix_case() {
  local id="$1"
  [[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || return 2
  [[ ! -e "${MATRIX_CAPTURE}/cases/${id}" ]] || { echo "cli matrix: duplicate case: ${id}" >&2; return 1; }
  CASE_PROFILE="${2:-test}"
  case "$CASE_PROFILE" in
    test) CASE_BIN="$MATRIX_TEST_BIN" ;;
    cpu) CASE_BIN="$MATRIX_CPU_BIN" ;;
    helper) [[ "${MATRIX_SELF_TEST:-0}" == 1 ]] || return 2; CASE_BIN="$(command -v bash)" ;;
    *) return 2 ;;
  esac
  CASE_ROOT="${TMP}/fixtures/${id}"
  CASE_DIR="${MATRIX_CAPTURE}/cases/${id}"
  CASE_STDIN="${CASE_DIR}/stdin"
  CASE_SETUP_COUNT=0
  export CASE_FILE_SIZE_LIMIT=""
  export HOME="${CASE_ROOT}/home" XDG_CONFIG_HOME="${CASE_ROOT}/config" XDG_DATA_HOME="${CASE_ROOT}/data"
  export XDG_CACHE_HOME="${CASE_ROOT}/cache" XDG_STATE_HOME="${CASE_ROOT}/state"
  CASE_DB="${XDG_DATA_HOME}/kotoba/memory.sqlite3"
  mkdir -p "$CASE_DIR" "$CASE_ROOT/work" "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"
  : >"$CASE_STDIN"
  cd "$CASE_ROOT/work"
  export CASE_ROOT CASE_DIR CASE_STDIN CASE_DB CASE_PROFILE CASE_BIN
}

matrix_setup() {
  local n="$CASE_SETUP_COUNT"
  CASE_SETUP_COUNT=$((CASE_SETUP_COUNT + 1))
  local status=0
  set -m
  timeout --kill-after=5s 120s "$CASE_BIN" "$@" < /dev/null >"$CASE_DIR/setup-${n}.stdout" 2>"$CASE_DIR/setup-${n}.stderr" &
  MATRIX_SETUP_PID=$!
  set +m
  wait "$MATRIX_SETUP_PID" || status=$?
  MATRIX_SETUP_PID=""
  printf '%s\n' "$status" >"$CASE_DIR/setup-${n}.status"
  return "$status"
}

matrix_run() {
  [[ ! -e "$CASE_DIR/receipt.json" ]] || return 2
  [[ -z "$CASE_FILE_SIZE_LIMIT" || "$CASE_FILE_SIZE_LIMIT" =~ ^[1-9][0-9]*$ ]] || {
    echo 'cli matrix: file size limit must be a positive integer' >&2
    return 2
  }
  matrix_python capture "$@" &
  MATRIX_CAPTURE_PID=$!
  local status=0
  wait "$MATRIX_CAPTURE_PID" || status=$?
  MATRIX_CAPTURE_PID=""
  return "$status"
}

# status N; stdout/stderr EXPECTED_FILE; fs-equal; db-equal;
# json success|success-source|error|doctor; json-values JSON_OBJECT;
# file ACTUAL EXPECTED; custom LABEL COMMAND [ARG...].
matrix_assert() {
  local status=0
  if [[ "$1" == custom ]]; then
    local label="$2"; shift 2
    "$@" >"$CASE_DIR/assert-${label}.stdout" 2>"$CASE_DIR/assert-${label}.stderr" || status=$?
    matrix_python verdict "$status" "$label"
  else
    matrix_python check "$@" >>"$CASE_DIR/assertions.stdout" 2>>"$CASE_DIR/assertions.stderr" || status=$?
    matrix_python verdict "$status" "$@"
  fi
  return "$status"
}

matrix_finish() { matrix_python finish; }

matrix_python() {
  local -a launcher=(python3)
  if [[ "$1" == capture ]]; then launcher=(exec python3); fi
  "${launcher[@]}" - "$@" <<'PY'
import hashlib
import json
import os
import resource
from pathlib import Path
import signal
import sqlite3
import stat
import subprocess
import sys
from contextlib import closing


def dump(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(root: Path, database: Path, destination: Path, phase: str) -> None:
    entries = []
    metadata = []
    for path in sorted(root.rglob("*")):
        mode = path.lstat().st_mode
        entry = {"path": str(path.relative_to(root)), "mode": stat.S_IMODE(mode)}
        if path.is_symlink():
            entry.update(type="symlink", target=os.readlink(path))
        elif path.is_file():
            entry.update(type="file", sha256=digest(path))
        elif path.is_dir():
            entry.update(type="directory")
        else:
            entry.update(type="special")
        entries.append(entry)
        metadata.append({"path": entry["path"], "mtime_ns": path.lstat().st_mtime_ns})
    dump(destination / f"fs-{phase}.json", entries)
    dump(destination / f"fs-metadata-{phase}.json", metadata)
    state = {"status": "absent"}
    if database.exists() or database.is_symlink():
        sidecars = [Path(str(database) + suffix) for suffix in ("-wal", "-shm")]
        journal = Path(str(database) + "-journal")
        try:
            with database.open("rb") as stream:
                header = stream.read(28)
        except OSError as error:
            state = {"status": "unreadable", "error": str(error)}
        else:
            unsafe = []
            if database.is_symlink():
                unsafe.append("database_symlink")
            if len(header) >= 20 and header[:16] == b"SQLite format 3\x00" and (header[18] == 2 or header[19] == 2):
                unsafe.append("wal_header")
            unsafe.extend(path.name[len(database.name):] for path in sidecars if path.exists() or path.is_symlink())
            if journal.exists() or journal.is_symlink():
                try:
                    with journal.open("rb") as stream:
                        journal_header = stream.read(28)
                except OSError:
                    unsafe.append("-journal")
                else:
                    if journal_header and any(journal_header):
                        unsafe.append("-journal")
            if unsafe:
                state = {"status": "skipped_unsafe", "reason": unsafe, "sqlite_opened": False}
            else:
                try:
                    with closing(sqlite3.connect(database.absolute().as_uri() + "?mode=ro", uri=True)) as db:
                        columns = [row[1] for row in db.execute("PRAGMA table_info(translations)")]
                        rows = list(db.execute("SELECT * FROM translations ORDER BY " + ",".join(str(i + 1) for i in range(len(columns)))))
                        state = {"status": "readable", "columns": columns, "rows": rows, "row_count": len(rows)}
                except sqlite3.Error as error:
                    state = {"status": "unreadable", "error": str(error)}
    dump(destination / f"db-{phase}.json", state)


def schema(value, kind: str) -> None:
    assert type(value) is dict, "JSON root must be an object"
    match kind:
        case "error":
            assert set(value) == {"error"} and type(value["error"]) is dict
            assert set(value["error"]) == {"code", "message"}
            assert all(type(item) is str for item in value["error"].values())
        case "doctor":
            assert set(value) == {"ok", "checks"} and type(value["ok"]) is bool
            assert type(value["checks"]) is list
            for check in value["checks"]:
                assert type(check) is dict and set(check) == {"name", "status", "code", "message"}
                assert all(type(item) is str for item in check.values())
        case "success" | "success-source":
            strings = {"source_lang", "target_lang", "mode", "model_id", "runtime", "cache_status", "translated_text"}
            if kind == "success-source":
                strings.add("source_text")
            counters = {"cached_segments", "total_segments", "elapsed_ms"}
            assert set(value) == strings | counters | {"cached", "warnings"}, "JSON field set"
            assert all(type(value[key]) is str for key in strings)
            assert all(type(value[key]) is int and value[key] >= 0 for key in counters), "nonnegative integer required"
            assert type(value["cached"]) is bool
            assert type(value["warnings"]) is list and all(type(item) is str for item in value["warnings"])
            cached, total = value["cached_segments"], value["total_segments"]
            assert cached <= total and value["cached"] == (cached == total)
            assert value["cache_status"] == ("none" if cached == 0 else "full" if cached == total else "partial")
        case _:
            raise AssertionError("unknown JSON schema")


def capture(args: list[str]) -> None:
    directory = Path(os.environ["CASE_DIR"])
    root, database = Path(os.environ["CASE_ROOT"]), Path(os.environ["CASE_DB"])
    executable = os.environ["CASE_BIN"]
    profile = os.environ["CASE_PROFILE"]
    file_size_limit = int(os.environ["CASE_FILE_SIZE_LIMIT"]) if os.environ["CASE_FILE_SIZE_LIMIT"] else None
    receipt = {"case_id": directory.name, "level": "helper" if profile == "helper" else "cli", "profile": profile,
               "group": os.environ["MATRIX_GROUP"],
               "executable": executable, "executable_sha256": digest(Path(executable)), "argv": [executable, *args],
               "stdin_sha256": digest(directory / "stdin"), "cwd": str(Path.cwd()), "fixture_root": str(root),
               "stdout": "stdout", "stderr": "stderr", "fs_before": "fs-before.json", "fs_after": "fs-after.json",
               "db_before": "db-before.json", "db_after": "db-after.json", "verdict": "pending", "assertions": [],
               "timeout_seconds": 120, "harness_timeout": False, "file_size_limit_bytes": file_size_limit}
    snapshot(root, database, directory, "before")
    dump(directory / "receipt.json", receipt)
    interrupted = 0
    process = None

    def stop(signum: int, _frame) -> None:
        nonlocal interrupted
        interrupted = signum
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def limit_child() -> None:
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE, (file_size_limit, file_size_limit))

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with (directory / "stdin").open("rb") as stdin, (directory / "stdout").open("wb") as stdout, (directory / "stderr").open("wb") as stderr:
        process = subprocess.Popen([executable, *args], stdin=stdin, stdout=stdout, stderr=stderr, start_new_session=True,
                                   preexec_fn=limit_child if file_size_limit is not None else None)
        try:
            process.wait(timeout=120)
        except subprocess.TimeoutExpired:
            receipt["harness_timeout"] = True
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    receipt["status"] = process.returncode if process.returncode >= 0 else 128 - process.returncode
    receipt["signal"] = interrupted
    (directory / "status").write_text(str(receipt["status"]) + "\n")
    snapshot(root, database, directory, "after")
    dump(directory / "receipt.json", receipt)
    if interrupted or receipt["harness_timeout"]:
        raise SystemExit(128 + interrupted if interrupted else 124)


def check(directory: Path, args: list[str]) -> None:
    match args:
        case ["status", expected]:
            receipt = json.loads((directory / "receipt.json").read_text())
            assert not receipt["harness_timeout"] and receipt["status"] == int(expected), "status mismatch"
        case [stream, expected] if stream in {"stdout", "stderr"}:
            assert (directory / stream).read_bytes() == Path(expected).read_bytes(), f"{stream} bytes mismatch"
        case [kind] if kind in {"fs-equal", "db-equal"}:
            prefix = kind.split("-")[0]
            assert (directory / f"{prefix}-before.json").read_bytes() == (directory / f"{prefix}-after.json").read_bytes(), f"{prefix} state mismatch"
            if kind == "fs-equal":
                assert (directory / "fs-metadata-before.json").read_bytes() == (directory / "fs-metadata-after.json").read_bytes(), "filesystem mtime mismatch"
        case ["json", kind]:
            schema(json.loads((directory / "stdout").read_bytes()), kind)
        case ["json-values", expected]:
            value = json.loads((directory / "stdout").read_bytes())
            for key, item in json.loads(expected).items():
                assert type(value[key]) is type(item) and value[key] == item, f"JSON value mismatch: {key}"
        case ["file", actual, expected]:
            assert Path(actual).read_bytes() == Path(expected).read_bytes(), "file bytes mismatch"
        case _:
            raise AssertionError("unknown assertion")


command, *arguments = sys.argv[1:]
directory = Path(os.environ["CASE_DIR"])
match command:
    case "capture":
        capture(arguments)
    case "check":
        check(directory, arguments)
    case "snapshot":
        snapshot(Path(os.environ["CASE_ROOT"]), Path(os.environ["CASE_DB"]), directory, arguments[0])
    case "verdict" | "finish":
        path = directory / "receipt.json"
        receipt = json.loads(path.read_text())
        if command == "verdict":
            receipt["assertions"].append({"check": arguments[1:], "passed": arguments[0] == "0"})
            receipt["verdict"] = "pending"
        else:
            assert receipt["assertions"] and all(item["passed"] for item in receipt["assertions"]), "missing or failed assertions"
            receipt["verdict"] = "pass"
        dump(path, receipt)
    case _:
        raise AssertionError("unknown helper operation")
PY
}
