#!/usr/bin/env bash
set -euo pipefail

matrix_memory_fixture() {
  matrix_case "$1"
  mkdir -p "$XDG_CONFIG_HOME/kotoba" "$XDG_DATA_HOME/kotoba"
  printf 'synthetic matrix model\n' >"$CASE_ROOT/model.gguf"
  printf 'model_id = "matrix-memory"\nmodel_path = "%s/model.gguf"\n' "$CASE_ROOT" >"$XDG_CONFIG_HOME/kotoba/config.toml"
  : >"$XDG_CONFIG_HOME/kotoba/glossary.toml"
  : >"$CASE_DIR/empty"
  python3 - "$CASE_DB" "$2" "$CASE_DIR" <<'PY'
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
from typing import assert_never

path, kind, destination = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
columns = "source_hash source_text translated_text source_lang target_lang mode model_id glossary_hash created_at updated_at hit_count".split()
match kind:
    case "absent":
        expected = {"status": "absent"}
    case "directory":
        path.mkdir()
        (path / "sentinel.txt").write_bytes(b"directory preserved\n")
        expected = {"status": "unreadable"}
    case "corrupt":
        path.write_bytes(b"not a sqlite database\n")
        expected = {"status": "unreadable"}
    case "healthy" | "sentinel" | "statement":
        rows = []
        with closing(sqlite3.connect(path)) as db:
            match kind:
                case "statement":
                    columns = ["sentinel"]
                    rows = [["schema preserved"]]
                    db.execute("CREATE TABLE translations (sentinel TEXT NOT NULL)")
                    db.execute("INSERT INTO translations VALUES (?)", rows[0])
                case "healthy" | "sentinel":
                    db.execute("""CREATE TABLE translations (
                        source_hash TEXT NOT NULL, source_text TEXT NOT NULL, translated_text TEXT NOT NULL,
                        source_lang TEXT NOT NULL, target_lang TEXT NOT NULL, mode TEXT NOT NULL,
                        model_id TEXT NOT NULL, glossary_hash TEXT NOT NULL,
                        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
                        hit_count INTEGER NOT NULL DEFAULT 0,
                        PRIMARY KEY (source_hash, source_lang, target_lang, mode, model_id, glossary_hash))""")
                    if kind == "sentinel":
                        rows = [[hashlib.sha256(b"Matrix sentinel").hexdigest(), "Matrix sentinel", "sentinel preserved",
                                 "en", "ja", "default", "matrix-memory", "1234", 10, 20, 7]]
                        db.execute("INSERT INTO translations VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows[0])
                case unreachable:
                    assert_never(unreachable)
            db.commit()
        expected = {"status": "readable", "columns": columns, "rows": rows, "row_count": len(rows)}
    case unreachable:
        assert_never(unreachable)
(destination / "fixture-db.json").write_text(json.dumps(expected))
PY
}

matrix_memory_glossary() {
  printf '[[terms]]\nsource = "CLI"\ntarget = "%s"\nmode = "%s"\n' "$2" "$1" >"$XDG_CONFIG_HOME/kotoba/glossary.toml"
}

matrix_memory_prime() {
  matrix_setup translate "$1" --from en --to ja --format json
}

matrix_memory_success() {
  python3 - "$1" "$2" "$CASE_DIR/expected.json" <<'PY'
import json
from pathlib import Path
import sys
text, cache, destination = sys.argv[1:]
cached, status, hits, segments = {"none": (False, "none", 0, 1), "full": (True, "full", 1, 1), "partial": (False, "partial", 1, 2)}[cache]
value = {"source_lang": "en", "target_lang": "ja", "mode": "default", "model_id": "matrix-memory", "runtime": "embedded",
         "cached": cached, "cache_status": status, "cached_segments": hits, "total_segments": segments,
         "translated_text": text, "warnings": []}
Path(destination).write_text(json.dumps(value))
PY
  matrix_assert status 0
  matrix_assert stderr "$CASE_DIR/empty"
  matrix_assert json success
  matrix_assert json-values "$(cat "$CASE_DIR/expected.json")"
}

matrix_memory_rows() {
  matrix_assert custom rows python3 - "$CASE_DIR" "$1" "$2" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys

directory = Path(sys.argv[1])
columns = "source_hash source_text translated_text source_lang target_lang mode model_id glossary_hash created_at updated_at hit_count".split()
hashes: dict[str, str] = {}
previous: dict[tuple[str, str], list[str | int]] = {}
for phase, expected in zip(("before", "after"), map(json.loads, sys.argv[2:]), strict=True):
    state = json.loads((directory / f"db-{phase}.json").read_text())
    assert state["status"] == "readable" and state["columns"] == columns, "healthy TM schema"
    assert state["row_count"] == len(state["rows"]) == len(expected), "TM row count"
    remaining = list(state["rows"])
    for source, hits, glossary in expected:
        candidates = [row for row in remaining if row[1] == source and
                      (row[7] == hashes[glossary] if glossary in hashes else row[7] not in hashes.values())]
        assert len(candidates) == 1, "TM glossary key relationship"
        row = candidates[0]
        remaining.remove(row)
        assert row[:7] == [hashlib.sha256(source.encode()).hexdigest(), source, "JA:" + source,
                           "en", "ja", "default", "matrix-memory"], "TM row values"
        assert type(row[7]) is str and re.fullmatch(r"[0-9a-f]+", row[7]), "TM glossary hash type"
        assert all(type(row[index]) is int and row[index] >= 0 for index in (8, 9, 10)), "TM integer fields"
        assert row[10] == hits, "TM hit count"
        hashes[glossary] = row[7]
        key = (source, glossary)
        if key in previous:
            old = previous[key]
            assert row[8] == old[8] and row[9] >= old[9], "TM timestamp preservation"
            if hits == old[10]:
                assert row == old, "untouched TM row"
        else:
            assert row[8] == row[9], "new TM timestamps"
        previous[key] = row
    assert not remaining, "unexpected TM row"
before, after = [{entry["path"]: entry for entry in json.loads((directory / f"fs-{phase}.json").read_text())}
                 for phase in ("before", "after")]
database = "data/kotoba/memory.sqlite3"
assert set(before) == set(after), "unexpected filesystem entry"
assert {path for path in before if before[path] != after[path]} == {database}, "only TM bytes may change"
assert {key: value for key, value in before[database].items() if key != "sha256"} == {
    key: value for key, value in after[database].items() if key != "sha256"}, "TM type/mode preservation"
print(json.dumps({"expected_before": json.loads(sys.argv[2]), "expected_after": json.loads(sys.argv[3]),
                  "glossary_keys": hashes, "changed_paths": [database]}))
PY
}

matrix_memory_preserved() {
  matrix_assert fs-equal
  matrix_assert db-equal
  matrix_assert custom preserved python3 - "$CASE_DIR" <<'PY'
import json
from pathlib import Path
import sys
directory = Path(sys.argv[1])
expected = json.loads((directory / "fixture-db.json").read_text())
for phase in ("before", "after"):
    state = json.loads((directory / f"db-{phase}.json").read_text())
    assert state["status"] == expected["status"], "explicit DB observation status"
    if expected["status"] == "unreadable":
        assert type(state["error"]) is str and state["error"], "missing unreadable reason"
    else:
        assert state == expected, "sentinel/schema/absent DB preservation"
print(json.dumps(expected))
PY
}

matrix_memory_broken_stdout_pipe() {
  matrix_memory_fixture tm-broken-stdout-pipe healthy
  printf 'kotoba: io_error: BrokenPipe\n' >"$CASE_DIR/expected.stderr"
  matrix_run_broken_stdout_pipe translate 'Matrix broken stdout pipe' --from en --to ja
  matrix_assert status 1
  matrix_assert stdout "$CASE_DIR/empty"
  matrix_assert stderr "$CASE_DIR/expected.stderr"
  matrix_memory_rows '[]' '[["Matrix broken stdout pipe",0,"empty"]]'
  matrix_assert custom closed-pipe-producer python3 - "$CASE_DIR" <<'PY'
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1])
receipt = json.loads((directory / "receipt.json").read_text())
assert receipt["level"] == "cli" and receipt["stdout_sink"] == "closed_pipe"
assert receipt["closed_stdout_pipe"] == {"reader_closed_before_exec": True, "producer_returncode": 1, "producer_status": 1}
assert (directory / "stdout").read_bytes() == b""
assert (directory / "stderr").read_bytes() == b"kotoba: io_error: BrokenPipe\n"
after = json.loads((directory / "db-after.json").read_text())
assert after["row_count"] == 1 and after["rows"][0][1:3] == ["Matrix broken stdout pipe", "JA:Matrix broken stdout pipe"]
print(json.dumps({"producer_status": receipt["closed_stdout_pipe"]["producer_status"], "tm_row_count": after["row_count"]}))
PY
  matrix_finish
}

matrix_memory() {
  local id kind source translated cache before after error_code error_message
  local -a flags
  matrix_memory_text_contract
  matrix_memory_broken_stdout_pipe
  for id in tm-miss tm-full-hit tm-partial-hit tm-disabled-flag tm-disabled-config \
    tm-directory-open-failure tm-corrupt-open-failure tm-statement-failure \
    glossary-prefer glossary-protect glossary-hash-change glossary-disabled-flag glossary-disabled-config \
    glossary-empty-key-reuse glossary-empty-key-reuse-config glossary-invalid-before-tm glossary-invalid-before-tm-absent; do
    kind=healthy source='Matrix cache alpha' cache=none flags=() error_code='' error_message=''
    before='[]' after='[["Matrix cache alpha",0,"empty"]]'
    case "$id" in
      tm-disabled-*|glossary-invalid-before-tm) kind=sentinel ;;
      tm-directory-open-failure) kind=directory ;;
      tm-corrupt-open-failure) kind=corrupt ;;
      tm-statement-failure) kind=statement ;;
      glossary-invalid-before-tm-absent) kind=absent ;;
    esac
    matrix_memory_fixture "$id" "$kind"
    case "$id" in
      glossary-*) source='Matrix glossary CLI'; after='[["Matrix glossary CLI",0,"prefer"]]' ;;
    esac
    case "$id" in
      tm-full-hit|tm-partial-hit)
        matrix_memory_prime "$source"
        before='[["Matrix cache alpha",0,"empty"]]'
        after='[["Matrix cache alpha",1,"empty"]]' cache=full
        if [[ "$id" == tm-partial-hit ]]; then
          source=$'Matrix cache alpha\n\nMatrix cache beta' cache=partial
          after='[["Matrix cache alpha",1,"empty"],["Matrix cache beta",0,"empty"]]'
        fi ;;
      tm-disabled-flag) flags=(--no-memory) ;;
      tm-disabled-config) printf 'memory_enabled = false\n' >>"$XDG_CONFIG_HOME/kotoba/config.toml" ;;
      tm-directory-open-failure|tm-corrupt-open-failure|tm-statement-failure)
        error_code=sqlite_failed; error_message='SQLite translation memory operation failed.' ;;
      glossary-prefer) matrix_memory_glossary prefer 'command line' ;;
      glossary-protect) matrix_memory_glossary protect 'command line'; after='[["Matrix glossary CLI",0,"protect"]]' ;;
      glossary-hash-change|glossary-disabled-flag|glossary-disabled-config)
        matrix_memory_glossary prefer 'command line'
        matrix_memory_prime "$source"
        before='[["Matrix glossary CLI",0,"prefer"]]'
        after='[["Matrix glossary CLI",0,"prefer"],["Matrix glossary CLI",0,"empty"]]'
        case "$id" in
          glossary-hash-change)
            matrix_memory_glossary prefer terminal
            after='[["Matrix glossary CLI",0,"prefer"],["Matrix glossary CLI",0,"changed"]]' ;;
          glossary-disabled-flag) flags=(--no-glossary) ;;
          glossary-disabled-config) printf 'glossary_enabled = false\n' >>"$XDG_CONFIG_HOME/kotoba/config.toml" ;;
        esac ;;
      glossary-empty-key-reuse|glossary-empty-key-reuse-config)
        matrix_memory_prime "$source"
        matrix_memory_glossary prefer 'command line'
        before='[["Matrix glossary CLI",0,"empty"]]' after='[["Matrix glossary CLI",1,"empty"]]' cache=full
        if [[ "$id" == glossary-empty-key-reuse ]]; then flags=(--no-glossary)
        else printf 'glossary_enabled = false\n' >>"$XDG_CONFIG_HOME/kotoba/config.toml"; fi ;;
      glossary-invalid-before-tm|glossary-invalid-before-tm-absent)
        matrix_memory_glossary invalid 'command line'
        error_code=glossary_invalid error_message='glossary.toml is invalid.' ;;
    esac
    translated="JA:$source"
    if [[ "$id" == tm-partial-hit ]]; then translated=$'JA:Matrix cache alpha\n\nJA:Matrix cache beta'; fi
    matrix_run translate "$source" --from en --to ja --format json "${flags[@]}"
    if [[ -n "$error_code" ]]; then
      printf '{"error":{"code":"%s","message":"%s"}}\n' "$error_code" "$error_message" >"$CASE_DIR/expected.stdout"
      matrix_assert status 1
      matrix_assert stdout "$CASE_DIR/expected.stdout"
      matrix_assert stderr "$CASE_DIR/empty"
      matrix_assert json error
    else
      matrix_memory_success "$translated" "$cache"
    fi
    if [[ "$kind" == healthy ]]; then matrix_memory_rows "$before" "$after"
    else matrix_memory_preserved; fi
    matrix_finish
  done
}

matrix_memory_raw_snapshot() {
  python3 - "$CASE_DB" "$CASE_DIR/raw-$1.json" <<'PY'
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
path, destination = map(Path, sys.argv[1:])
before = hashlib.sha256(path.read_bytes()).hexdigest()
sidecars = {suffix: Path(str(path) + suffix).exists() for suffix in ('-wal', '-shm', '-journal')}
assert not any(sidecars.values()), 'unexpected fixture sidecar'
with closing(sqlite3.connect(path.absolute().as_uri() + '?mode=ro', uri=True)) as db:
    cursor = db.execute('''SELECT source_hash, hex(CAST(source_text AS BLOB)) AS source_hex,
        length(CAST(source_text AS BLOB)) AS source_bytes,
        hex(CAST(translated_text AS BLOB)) AS translated_hex,
        length(CAST(translated_text AS BLOB)) AS translated_bytes,
        source_lang, target_lang, mode, model_id, glossary_hash, created_at, updated_at, hit_count
        FROM translations ORDER BY source_hash, source_lang, target_lang, mode, model_id, glossary_hash''')
    rows = cursor.fetchall()
    columns = [column[0] for column in cursor.description]
    count = db.execute('SELECT COUNT(*) FROM translations').fetchone()[0]
assert count == len(rows)
assert hashlib.sha256(path.read_bytes()).hexdigest() == before, 'observer mutated DB'
assert all(Path(str(path) + suffix).exists() == exists for suffix, exists in sidecars.items())
destination.write_text(json.dumps(dict(columns=columns, rows=rows, row_count=count,
                                      database_sha256=before, sidecars=sidecars), indent=2) + '\n')
PY
}

matrix_memory_text_contract() {
  local field defect code message source
  for field in source output; do
    for defect in utf8 nul; do
      matrix_memory_fixture "tm-text-contract-legacy-$field-$defect" healthy
      matrix_memory_prime Hello
      python3 - "$CASE_DB" "$field" "$defect" <<'PY'
from contextlib import closing
import sqlite3
import sys
path, field, defect = sys.argv[1:]
column = {'source': 'source_text', 'output': 'translated_text'}[field]
payload = {'utf8': b'A\xffB', 'nul': b'A\x00B'}[defect]
with closing(sqlite3.connect(path)) as db:
    assert db.execute('SELECT source_text, translated_text FROM translations').fetchall() == [('Hello', 'JA:Hello')]
    db.execute(f'UPDATE translations SET {column}=CAST(? AS TEXT), hit_count=7, created_at=11, updated_at=13', (payload,))
    db.commit()
PY
      matrix_memory_raw_snapshot before
      matrix_run translate Hello --from en --to ja --format json
      matrix_memory_raw_snapshot after
      code=invalid_utf8 message='Text must be valid UTF-8.'
      if [[ "$defect" == nul ]]; then code=embedded_nul message='Text must not contain NUL bytes.'; fi
      printf '{"error":{"code":"%s","message":"%s"}}\n' "$code" "$message" >"$CASE_DIR/expected.stdout"
      matrix_assert status 1
      matrix_assert stdout "$CASE_DIR/expected.stdout"
      matrix_assert stderr "$CASE_DIR/empty"
      matrix_assert json error
      matrix_assert json-values "$(cat "$CASE_DIR/expected.stdout")"
      matrix_assert fs-equal
      matrix_assert db-equal
      matrix_assert custom raw-legacy-preserved python3 - "$CASE_DIR" "$field" "$defect" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
directory, field, defect = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
before, after = [json.loads((directory / f'raw-{phase}.json').read_text()) for phase in ('before', 'after')]
assert before == after, 'raw DB rows/hash/sidecars changed'
assert before['row_count'] == 1
row = dict(zip(before['columns'], before['rows'][0], strict=True))
payload = {'utf8': b'A\xffB', 'nul': b'A\x00B'}[defect]
source, output = (payload, b'JA:Hello') if field == 'source' else (b'Hello', payload)
assert row == dict(source_hash=hashlib.sha256(b'Hello').hexdigest(), source_hex=source.hex().upper(),
    source_bytes=len(source), translated_hex=output.hex().upper(), translated_bytes=len(output),
    source_lang='en', target_lang='ja', mode='default', model_id='matrix-memory',
    glossary_hash='409638ee2bde459', created_at=11, updated_at=13, hit_count=7)
print(json.dumps({'raw_equal': True, 'database_sha256': before['database_sha256'], 'row': row}))
PY
      matrix_finish
    done
  done

  source='Hello 日本語😀é'
  matrix_memory_fixture tm-text-contract-unicode-hit healthy
  matrix_memory_prime "$source"
  matrix_memory_raw_snapshot before
  matrix_run translate "$source" --from en --to ja --format json
  matrix_memory_raw_snapshot after
  matrix_memory_success "JA:$source" full
  matrix_memory_rows '[["Hello 日本語😀é",0,"empty"]]' '[["Hello 日本語😀é",1,"empty"]]'
  matrix_assert custom raw-unicode-hit python3 - "$CASE_DIR" <<'PY'
import json
from pathlib import Path
import sys
directory = Path(sys.argv[1])
before, after = [json.loads((directory / f'raw-{phase}.json').read_text()) for phase in ('before', 'after')]
assert before['row_count'] == after['row_count'] == 1
assert before['columns'] == after['columns'] and before['sidecars'] == after['sidecars']
old, new = [dict(zip(state['columns'], state['rows'][0], strict=True)) for state in (before, after)]
assert new['hit_count'] == old['hit_count'] + 1
assert new['updated_at'] >= old['updated_at']
assert {k: v for k, v in old.items() if k not in ('hit_count', 'updated_at')} == {
    k: v for k, v in new.items() if k not in ('hit_count', 'updated_at')}
print(json.dumps({'before': old, 'after': new, 'only_allowed_changes': ['hit_count', 'updated_at']}))
PY
  matrix_finish
}
