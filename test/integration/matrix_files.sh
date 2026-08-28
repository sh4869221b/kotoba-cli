#!/usr/bin/env bash
set -euo pipefail

matrix_files_fixture() {
  matrix_case "files-$1"
  printf 'synthetic file matrix model' >"$CASE_ROOT/model.gguf"
  matrix_setup init --model-id matrix-files --model-path "$CASE_ROOT/model.gguf" --yes
  matrix_setup translate files-sentinel --from en --to ja
  printf 'unrelated sibling\n' >"untouched sibling.txt"
  : >"$CASE_DIR/empty"
  printf 'JA:Hello' >"$CASE_DIR/expected.file"
  printf 'destination sentinel\n' >"$CASE_DIR/expected.sentinel"
}

matrix_files_run() {
  date +%s >"$CASE_DIR/start-second"
  matrix_run "$@"
  date +%s >"$CASE_DIR/end-second"
}

matrix_files_streams() {
  matrix_assert status "$1"
  matrix_assert stdout "$CASE_DIR/empty"
  if [[ $# == 1 ]]; then
    matrix_assert stderr "$CASE_DIR/empty"
  else
    printf 'kotoba: %s: %s\n' "$2" "$3" >"$CASE_DIR/expected.stderr"
    matrix_assert stderr "$CASE_DIR/expected.stderr"
  fi
}

# Only the named destination and, when requested, one fresh TM row may change.
# Native prefix cases also prove cleanup after a real partial stage write.
matrix_files_state() {
  local action="$1" destination="$2" rows="$3"
  if [[ "$action" != unchanged ]]; then
    matrix_assert file "$destination" "$CASE_DIR/expected.file"
    cp "$destination" "$CASE_DIR/actual.file"
  fi
  if [[ "$rows" == 0 ]]; then matrix_assert db-equal; fi
  matrix_assert custom destination-and-memory python3 - "$CASE_DIR" "$action" "work/$destination" "$rows" "$(umask)" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1])
action, destination = sys.argv[2:4]
added_rows, mask = int(sys.argv[4]), int(sys.argv[5], 8)
before, after = [{entry["path"]: entry for entry in json.loads((directory / f"fs-{phase}.json").read_text())}
                 for phase in ("before", "after")]
expected = dict(before)
if action != "unchanged":
    assert action in {"create", "replace"}
    if action == "create":
        assert destination not in before, "destination must start absent"
        mode = 0o666 & ~mask
    else:
        assert before[destination]["type"] == "file", "replacement must start as a regular file"
        mode = before[destination]["mode"]
    expected[destination] = {"path": destination, "type": "file", "mode": mode,
                             "sha256": hashlib.sha256((directory / "expected.file").read_bytes()).hexdigest()}

database = "data/kotoba/memory.sqlite3"
if added_rows:
    assert added_rows == 1
    assert before[database]["sha256"] != after[database]["sha256"], "TM bytes must change on insert"
    expected[database] = dict(before[database], sha256=after[database]["sha256"])
assert after == expected, "unexpected filesystem entry, content, type, or mode change"

columns = "source_hash source_text translated_text source_lang target_lang mode model_id glossary_hash created_at updated_at hit_count".split()
db_before, db_after = [json.loads((directory / f"db-{phase}.json").read_text()) for phase in ("before", "after")]
for state in (db_before, db_after):
    assert state["status"] == "readable" and state["columns"] == columns
    assert state["row_count"] == len(state["rows"])
assert db_before["row_count"] == 1 and db_after["row_count"] == 1 + added_rows, "TM row delta"

# Empty glossary hash is pinned from the baseline and the unchanged empty template.
def expected_values(source):
    return [hashlib.sha256(source.encode()).hexdigest(), source, "JA:" + source,
            "en", "ja", "default", "matrix-files", "409638ee2bde459"]

sentinel = db_before["rows"][0]
assert sentinel[:8] == expected_values("files-sentinel") and sentinel[10] == 0
assert all(type(sentinel[index]) is int and sentinel[index] >= 0 for index in (8, 9, 10))
assert sentinel[8] == sentinel[9]
assert sentinel in db_after["rows"], "sentinel row or hit count changed"
if added_rows:
    inserted = [row for row in db_after["rows"] if row != sentinel]
    assert len(inserted) == 1
    row = inserted[0]
    assert row[:8] == expected_values("Hello") and row[10] == 0, "inserted row values/hits"
    assert all(type(row[index]) is int for index in (8, 9, 10))
    start, end = [int((directory / f"{edge}-second").read_text()) for edge in ("start", "end")]
    assert start <= row[8] == row[9] <= end, "insert timestamps outside measured command"
else:
    assert db_after == db_before, "TM changed despite zero expected delta"
print(json.dumps({"destination_action": action, "destination": destination,
                  "added_rows": added_rows, "hit_delta": 0,
                  "changed_paths": sorted(path for path in after if before.get(path) != after[path])}))
PY
}

matrix_files() {
  local reader format destination source extension memory rows scenario action
  local -a input_args flags

  # Explicit destinations take precedence even over JSON rendering and Markdown siblings.
  for reader in direct stdin txt md; do
    for format in plain json; do
      matrix_files_fixture "explicit-$reader-$format"
      destination="destination 'quoted' file.txt"
      input_args=()
      case "$reader" in
        direct) input_args=(Hello) ;;
        stdin) printf Hello >"$CASE_STDIN" ;;
        txt|md)
          source="source \"quoted\".$reader"
          printf Hello >"$source"
          input_args=(--file "$source")
          ;;
      esac
      matrix_files_run translate "${input_args[@]}" --from en --to ja --format "$format" --output "$destination" --no-memory
      matrix_files_streams 0
      matrix_files_state create "$destination" 0
      matrix_finish
    done
  done

  for extension in md markdown; do
    matrix_files_fixture "default-sibling-$extension"
    source="source \"quoted\".$extension"
    destination='source "quoted".ja.md'
    if [[ "$extension" == markdown ]]; then destination="$source.ja.md"; fi
    printf Hello >"$source"
    matrix_files_run translate --file "$source" --from en --to ja --no-memory
    matrix_files_streams 0
    matrix_files_state create "$destination" 0
    matrix_finish
  done

  for scenario in native-prefix native-prefix-absent; do
    matrix_files_fixture "atomic-$scenario"
    destination=output.txt
    if [[ "$scenario" == native-prefix ]]; then cp "$CASE_DIR/expected.sentinel" "$destination"; fi
    printf -v source '%4096s' ''
    source="${source// /X}"
    export CASE_FILE_SIZE_LIMIT=1024
    matrix_files_run translate "$source" --from en --to ja --output "$destination" --overwrite --no-memory --no-glossary
    matrix_files_streams 1 io_error FileTooBig
    matrix_files_state unchanged "$destination" 0
    matrix_assert custom native-limit python3 - "$CASE_DIR" <<'PY'
import json
from pathlib import Path
import sys
receipt = json.loads((Path(sys.argv[1]) / "receipt.json").read_text())
assert receipt["level"] == "cli" and receipt["file_size_limit_bytes"] == 1024
assert receipt["argv"][2] == "X" * 4096
print('{"input_length":4096,"file_size_limit_bytes":1024,"stage_cleaned":true}')
PY
    matrix_finish
  done

  local mode
  for mode in 600 640; do
    matrix_files_fixture "atomic-mode-$mode"
    destination=output.txt
    cp "$CASE_DIR/expected.sentinel" "$destination"
    chmod "$mode" "$destination"
    matrix_files_run translate Hello --from en --to ja --output "$destination" --overwrite --no-memory
    matrix_files_streams 0
    matrix_files_state replace "$destination" 0
    matrix_finish
  done

  for scenario in symlink dangling hardlink; do
    for action in reject replace; do
      matrix_files_fixture "atomic-$scenario-$action"
      destination=output.txt
      if [[ "$scenario" != dangling ]]; then cp "$CASE_DIR/expected.sentinel" target.txt; fi
      if [[ "$scenario" == hardlink ]]; then ln target.txt "$destination"; else ln -s target.txt "$destination"; fi
      python3 - "$CASE_DIR/link-before.json" <<'PY'
import json
import os
from pathlib import Path
import sys
value = {}
for name in ("output.txt", "target.txt"):
    if os.path.lexists(name):
        info = os.lstat(name)
        value[name] = {"dev": info.st_dev, "inode": info.st_ino, "links": info.st_nlink, "mode": info.st_mode}
Path(sys.argv[1]).write_text(json.dumps(value) + "\n")
PY
      flags=()
      if [[ "$action" == replace ]]; then flags=(--overwrite); fi
      matrix_files_run translate Hello --from en --to ja --output "$destination" "${flags[@]}" --no-memory
      if [[ "$action" == replace ]]; then
        matrix_files_streams 0
        matrix_assert file "$destination" "$CASE_DIR/expected.file"
      else
        matrix_files_streams 1 output_exists 'Output file already exists. Use --overwrite to replace it.'
        matrix_assert fs-equal
      fi
      matrix_assert db-equal
      matrix_assert custom link-identity python3 - "$CASE_DIR" "$scenario" "$action" "$(umask)" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
root, scenario, action, mask = Path(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4], 8)
old = json.loads((root / "link-before.json").read_text())
new = {}
for name in old:
    info = os.lstat(name)
    new[name] = {"dev": info.st_dev, "inode": info.st_ino, "links": info.st_nlink, "mode": info.st_mode}
before, after = [{entry["path"]: entry for entry in json.loads((root / f"fs-{phase}.json").read_text())}
                 for phase in ("before", "after")]
expected = dict(before)
if action == "replace":
    info = os.lstat("output.txt")
    assert stat.S_ISREG(info.st_mode) and info.st_ino != old["output.txt"]["inode"]
    mode = before["work/output.txt"]["mode"] if scenario == "hardlink" else 0o666 & ~mask
    expected["work/output.txt"] = {"path": "work/output.txt", "type": "file", "mode": mode,
                                  "sha256": hashlib.sha256((root / "expected.file").read_bytes()).hexdigest()}
else:
    assert new == old, "rejected output changed entry identity"
if scenario == "dangling":
    assert not os.path.lexists("target.txt")
else:
    assert Path("target.txt").read_bytes() == (root / "expected.sentinel").read_bytes()
    expected_target = dict(old["target.txt"])
    if scenario == "hardlink" and action == "replace": expected_target["links"] -= 1
    assert new["target.txt"] == expected_target, "link target inode, mode, or link count changed"
assert after == expected, "unexpected entry, type, mode, bytes, or leftover stage"
print(json.dumps({"scenario": scenario, "action": action, "before": old, "after": new, "entry_set_exact": True}))
PY
      matrix_finish
    done
  done

  matrix_files_fixture atomic-parent-permission
  [[ "$(id -u)" != 0 ]] || { echo 'cli matrix: native permission test requires an unprivileged UID' >&2; return 1; }
  mkdir locked
  destination=locked/output.txt
  cp "$CASE_DIR/expected.sentinel" "$destination"
  chmod 555 locked
  local run_status=0
  matrix_files_run translate Hello --from en --to ja --output "$destination" --overwrite --no-memory || run_status=$?
  chmod 755 locked
  stat -c '%a' locked >"$CASE_DIR/restored-mode.txt"
  [[ "$run_status" == 0 ]]
  matrix_files_streams 1 io_error AccessDenied
  matrix_files_state unchanged "$destination" 0
  matrix_finish

  for memory in enabled disabled; do
    flags=() rows=1
    if [[ "$memory" == disabled ]]; then flags+=(--no-memory); rows=0; fi
    for scenario in output-exists overwrite alias-exists alias-overwrite missing-parent directory-exists directory-open; do
      matrix_files_fixture "$scenario-$memory"
      destination="destination 'quoted' file.txt"
      input_args=(Hello) action=unchanged
      case "$scenario" in
        output-exists|overwrite)
          cp "$CASE_DIR/expected.sentinel" "$destination"
          if [[ "$scenario" == overwrite ]]; then action=replace; fi
          ;;
        alias-exists|alias-overwrite)
          destination='source "quoted".txt'
          printf Hello >"$destination"
          input_args=(--file "$destination")
          if [[ "$scenario" == alias-overwrite ]]; then action=replace; fi
          ;;
        missing-parent) destination="missing parent/destination 'quoted'.txt" ;;
        directory-exists|directory-open)
          destination="destination 'quoted' directory"
          mkdir "$destination"
          cp "$CASE_DIR/expected.sentinel" "$destination/sentinel.txt"
          mkdir "$destination/nested"
          printf 'nested sentinel\n' >"$destination/nested/untouched.txt"
          ;;
      esac
      local -a overwrite=()
      if [[ "$action" == replace || "$scenario" == directory-open ]]; then overwrite=(--overwrite); fi
      matrix_files_run translate "${input_args[@]}" --from en --to ja --output "$destination" "${overwrite[@]}" "${flags[@]}"
      case "$scenario" in
        overwrite|alias-overwrite) matrix_files_streams 0 ;;
        output-exists|alias-exists|directory-exists)
          matrix_files_streams 1 output_exists 'Output file already exists. Use --overwrite to replace it.'
          ;;
        missing-parent) matrix_files_streams 1 io_error FileNotFound ;;
        directory-open) matrix_files_streams 1 io_error IsDir ;;
      esac
      matrix_files_state "$action" "$destination" "$rows"
      matrix_finish
    done

    # These inputs fail before translation, even when overwrite would permit replacement.
    for scenario in empty-direct empty-stdin empty-file conflicting-input missing-input; do
      matrix_files_fixture "$scenario-$memory"
      destination="destination 'quoted' file.txt"
      cp "$CASE_DIR/expected.sentinel" "$destination"
      input_args=()
      case "$scenario" in
        empty-direct) input_args=('') ;;
        empty-stdin) : >"$CASE_STDIN" ;;
        empty-file) : >'empty input.txt'; input_args=(--file 'empty input.txt') ;;
        conflicting-input) printf Hello >'input.txt'; input_args=(Hello --file input.txt) ;;
        missing-input) input_args=(--file 'missing input.txt') ;;
      esac
      matrix_files_run translate "${input_args[@]}" --from en --to ja --output "$destination" --overwrite "${flags[@]}"
      if [[ "$scenario" == missing-input ]]; then
        matrix_files_streams 1 io_error FileNotFound
      else
        matrix_files_streams 2 invalid_arguments 'Invalid arguments.'
      fi
      matrix_files_state unchanged "$destination" 0
      matrix_finish
    done
  done
}
