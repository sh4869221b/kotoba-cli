#!/usr/bin/env bash
set -euo pipefail

matrix_translate_fixture() {
  matrix_case "translate-$1"
  printf 'synthetic translation model bytes' >"$CASE_ROOT/model.gguf"
  matrix_setup init --model-id matrix-translate --model-path "$CASE_ROOT/model.gguf" --yes
  matrix_setup translate memory-sentinel --from en --to ja
  : >"$CASE_DIR/empty"
}

matrix_translate_state() {
  matrix_assert db-equal
  matrix_assert custom seeded-db python3 - "$CASE_DIR/db-before.json" <<'PY'
import json
from pathlib import Path
import sys
state = json.loads(Path(sys.argv[1]).read_text())
assert state["status"] == "readable" and state["row_count"] == 1
row = dict(zip(state["columns"], state["rows"][0]))
assert row["source_text"] == "memory-sentinel" and row["translated_text"] == "JA:memory-sentinel"
assert row["hit_count"] == 0
PY
}

matrix_translate_json() {
  local from="$1" to="$2" translated="$3" mode="${4:-default}" schema=success
  if [[ $# == 5 ]]; then schema=success-source; fi
  python3 - "$from" "$to" "$translated" "$mode" "${5:-}" "$schema" >"$CASE_DIR/expected.json" <<'PY'
import json
import sys
source_lang, target_lang, translated, mode, source, schema = sys.argv[1:]
value = {"source_lang": source_lang, "target_lang": target_lang, "mode": mode,
         "model_id": "matrix-translate", "runtime": "embedded", "cached": False,
         "cache_status": "none", "cached_segments": 0, "total_segments": 1,
         "translated_text": translated, "warnings": []}
if schema == "success-source":
    value["source_text"] = source
print(json.dumps(value, ensure_ascii=False))
PY
  matrix_assert json "$schema"
  matrix_assert json-values "$(cat "$CASE_DIR/expected.json")"
  matrix_assert custom json-newline python3 - "$CASE_DIR/stdout" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_bytes().endswith(b"\n")
PY
}

matrix_translate_destination() {
  local destination="$1"
  matrix_assert stdout "$CASE_DIR/empty"
  matrix_assert file "$destination" "$CASE_DIR/expected.file"
  matrix_assert custom destination-state python3 - "$CASE_DIR" "work/$destination" "$(umask)" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
directory, destination, mask = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3], 8)
before = {entry["path"]: entry for entry in json.loads((directory / "fs-before.json").read_text())}
after = {entry["path"]: entry for entry in json.loads((directory / "fs-after.json").read_text())}
assert set(after) - set(before) == {destination}
assert set(before) - set(after) == set()
assert all(after[path] == entry for path, entry in before.items()), "preexisting entry changed"
assert after[destination] == {"path": destination, "type": "file", "mode": 0o666 & ~mask,
                              "sha256": hashlib.sha256((directory / "expected.file").read_bytes()).hexdigest()}
PY
}

matrix_translate_plain_extra() {
  local id="$1" source="$2" expected="$3" format="$4"
  matrix_translate_fixture "$id"
  printf '%s\n' "$expected" >"$CASE_DIR/expected.stdout"
  matrix_run translate "$source" --from en --to ja --format "$format" --no-memory
  matrix_assert status 0
  matrix_assert stdout "$CASE_DIR/expected.stdout"
  matrix_assert stderr "$CASE_DIR/empty"
  matrix_assert fs-equal
  matrix_translate_state
  matrix_finish
}

matrix_translate() {
  local from to source translated reader format destination id
  local -a input_args extra_args
  matrix_translate_text_contract
  for from in en ja; do
    if [[ "$from" == en ]]; then
      to=ja source=Hello translated=JA:Hello
    else
      to=en source=こんにちは translated=EN:こんにちは
    fi
    for reader in direct stdin txt md; do
      for format in plain markdown json; do
        matrix_translate_fixture "$from-$to-$reader-$format"
        input_args=() destination=""
        case "$reader" in
          direct) input_args=("$source") ;;
          stdin) printf '%s' "$source" >"$CASE_STDIN" ;;
          txt|md)
            printf '%s' "$source" >"input.$reader"
            input_args=(--file "input.$reader")
            if [[ "$reader" == md ]]; then
              destination="input.$to.md"
            elif [[ "$format" == markdown ]]; then
              destination="input.txt.$to.md"
            fi
            ;;
        esac
        printf '%s\n' "$translated" >"$CASE_DIR/expected.stdout"
        printf '%s' "$translated" >"$CASE_DIR/expected.file"
        matrix_run translate "${input_args[@]}" --from "$from" --to "$to" --format "$format" --no-memory
        matrix_assert status 0
        matrix_assert stderr "$CASE_DIR/empty"
        if [[ -n "$destination" ]]; then
          matrix_translate_destination "$destination"
        else
          if [[ "$format" == json ]]; then
            matrix_translate_json "$from" "$to" "$translated"
          else
            matrix_assert stdout "$CASE_DIR/expected.stdout"
          fi
          matrix_assert fs-equal
        fi
        matrix_translate_state
        matrix_finish
      done
    done
  done

  source=$'First "quoted"\\path\t終\nSecond'
  translated=$'JA:First "quoted"\\path\t終\nSecond'
  for id in multiline-plain multiline-json include-source-json; do
    matrix_translate_fixture "$id"
    printf '%s' "$source" >"$CASE_STDIN"
    printf '%s\n' "$translated" >"$CASE_DIR/expected.stdout"
    format=json extra_args=()
    if [[ "$id" == multiline-plain ]]; then format=plain; fi
    if [[ "$id" == include-source-json ]]; then extra_args=(--include-source); fi
    matrix_run translate --from en --to ja --format "$format" --no-memory "${extra_args[@]}"
    matrix_assert status 0
    matrix_assert stderr "$CASE_DIR/empty"
    if [[ "$format" == plain ]]; then
      matrix_assert stdout "$CASE_DIR/expected.stdout"
    elif [[ "$id" == include-source-json ]]; then
      matrix_translate_json en ja "$translated" default "$source"
    else
      matrix_translate_json en ja "$translated"
    fi
    matrix_assert fs-equal
    matrix_translate_state
    matrix_finish
  done

  matrix_translate_fixture technical-json
  matrix_run translate こんにちは --from ja --to en --mode technical --format json --no-memory
  matrix_assert status 0
  matrix_assert stderr "$CASE_DIR/empty"
  matrix_translate_json ja en EN:こんにちは technical
  matrix_assert fs-equal
  matrix_translate_state
  matrix_finish

  for id in flag config json; do
    matrix_translate_fixture "debug-$id"
    source="private-source-$id"
    printf 'JA:%s\n' "$source" >"$CASE_DIR/expected.stdout"
    printf 'kotoba: debug: diagnostics enabled\n' >"$CASE_DIR/expected.stderr"
    extra_args=(--debug) format=plain
    if [[ "$id" == config ]]; then
      matrix_setup config set log_level debug
      extra_args=()
    elif [[ "$id" == json ]]; then
      format=json
    fi
    matrix_run translate "$source" --from en --to ja --format "$format" --no-memory "${extra_args[@]}"
    matrix_assert status 0
    matrix_assert stderr "$CASE_DIR/expected.stderr"
    if [[ "$format" == json ]]; then
      matrix_translate_json en ja "JA:$source"
    else
      matrix_assert stdout "$CASE_DIR/expected.stdout"
    fi
    matrix_assert custom no-bodies python3 - "$CASE_DIR/stderr" "$source" "JA:$source" <<'PY'
from pathlib import Path
import sys
stderr = Path(sys.argv[1]).read_bytes()
assert all(body.encode() not in stderr for body in sys.argv[2:])
PY
    matrix_assert fs-equal
    matrix_translate_state
    matrix_finish
  done

  matrix_translate_plain_extra markdown-fenced $'Hello\n\n```zig\nconst answer = 42;\n```' $'JA:Hello\n\n```zig\nconst answer = 42;\n```' markdown
  matrix_translate_plain_extra markdown-inline 'Use `code` now' 'JA:Use `code` now' markdown
  matrix_translate_plain_extra markdown-table $'Hello\n\n| A | B |\n| - | - |\n| left | right |' $'JA:Hello\n\n| A | B |\n| - | - |\n| left | right |' markdown
  matrix_translate_plain_extra markdown-link-url 'See [site](https://example.test/a?q=1) now.' 'JA:See [site](https://example.test/a?q=1) now.' markdown
  matrix_translate_plain_extra markdown-all-protected $'```txt\nliteral\n```' $'```txt\nliteral\n```' markdown

  for id in short symbol-only; do
    matrix_translate_fixture "ambiguous-$id"
    source=Hi
    if [[ "$id" == symbol-only ]]; then source='123 !?'; fi
    printf 'kotoba: invalid_arguments: Source language is ambiguous. Specify --from en or --from ja.\n' >"$CASE_DIR/expected.stderr"
    matrix_run translate "$source" --to ja --no-memory
    matrix_assert status 2
    matrix_assert stdout "$CASE_DIR/empty"
    matrix_assert stderr "$CASE_DIR/expected.stderr"
    matrix_assert fs-equal
    matrix_translate_state
    matrix_finish
  done

  for reader in direct stdin file; do
    matrix_translate_fixture "empty-$reader"
    input_args=()
    case "$reader" in
      direct) input_args=('') ;;
      file) : >input.txt; input_args=(--file input.txt) ;;
    esac
    printf 'kotoba: invalid_arguments: Invalid arguments.\n' >"$CASE_DIR/expected.stderr"
    matrix_run translate "${input_args[@]}" --to ja --no-memory
    matrix_assert status 2
    matrix_assert stdout "$CASE_DIR/empty"
    matrix_assert stderr "$CASE_DIR/expected.stderr"
    matrix_assert fs-equal
    matrix_translate_state
    matrix_finish
  done

  for option in input adapter; do
    matrix_translate_fixture "unsupported-$option-option"
    printf 'kotoba: invalid_arguments: Invalid arguments.\n' >"$CASE_DIR/expected.stderr"
    matrix_run translate Hello "--$option" fixture --from en --to ja --no-memory
    matrix_assert status 2
    matrix_assert stdout "$CASE_DIR/empty"
    matrix_assert stderr "$CASE_DIR/expected.stderr"
    matrix_assert fs-equal
    matrix_translate_state
    matrix_finish
  done
}

matrix_translate_text_contract() {
  local id code message
  matrix_translate_fixture text-contract-valid-json
  python3 - "$CASE_STDIN" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'A' + bytes(range(1, 32)) + '日本語😀é'.encode() + b'Z')
PY
  matrix_run translate --from en --to ja --format json --include-source --no-memory
  matrix_assert status 0
  matrix_assert stderr "$CASE_DIR/empty"
  matrix_translate_json en ja "JA:$(cat "$CASE_STDIN")" default "$(cat "$CASE_STDIN")"
  matrix_assert custom exact-text-bytes python3 - "$CASE_DIR" <<'PY'
import json
from pathlib import Path
import sys
directory = Path(sys.argv[1])
source = (directory / 'stdin').read_bytes()
value = json.loads((directory / 'stdout').read_bytes())
assert value['source_text'].encode() == source
assert value['translated_text'].encode() == b'JA:' + source
print(json.dumps({'source_hex': source.hex(), 'translated_hex': value['translated_text'].encode().hex()}))
PY
  matrix_assert fs-equal
  matrix_translate_state
  matrix_finish

  for id in invalid-stdin-human nul-stdin-json truncated-file nul-file invalid-glossary nul-glossary; do
    matrix_translate_fixture "text-contract-$id"
    code=invalid_utf8 message='Text must be valid UTF-8.'
    if [[ "$id" == nul-* ]]; then code=embedded_nul message='Text must not contain NUL bytes.'; fi
    case "$id" in
      invalid-stdin-human) printf 'A\377B' >"$CASE_STDIN" ;;
      nul-stdin-json) printf 'A\000B' >"$CASE_STDIN" ;;
      truncated-file) printf '\343\201' >invalid.md ;;
      nul-file) printf 'A\000B' >invalid.txt ;;
      *-glossary)
        printf '[[terms]]\nsource = "Hello"\ntarget = "A' >"$XDG_CONFIG_HOME/kotoba/glossary.toml"
        if [[ "$id" == invalid-* ]]; then printf '\377'; else printf '\000'; fi >>"$XDG_CONFIG_HOME/kotoba/glossary.toml"
        printf 'B"\n' >>"$XDG_CONFIG_HOME/kotoba/glossary.toml" ;;
    esac
    case "$id" in
      invalid-stdin-human) matrix_run translate --from en --to ja ;;
      nul-stdin-json) matrix_run translate --from en --to ja --format json ;;
      truncated-file) matrix_run translate --file invalid.md --from en --to ja --output rejected.md ;;
      nul-file) matrix_run translate --file invalid.txt --from en --to ja --output rejected.txt --format json ;;
      *-glossary) matrix_run translate Hello --from en --to ja ;;
    esac
    matrix_assert status 1
    if [[ "$id" == nul-stdin-json || "$id" == nul-file ]]; then
      printf '{"error":{"code":"%s","message":"%s"}}\n' "$code" "$message" >"$CASE_DIR/expected.stdout"
      matrix_assert stdout "$CASE_DIR/expected.stdout"
      matrix_assert stderr "$CASE_DIR/empty"
      matrix_assert json error
      matrix_assert json-values "$(cat "$CASE_DIR/expected.stdout")"
    else
      printf 'kotoba: %s: %s\n' "$code" "$message" >"$CASE_DIR/expected.stderr"
      matrix_assert stdout "$CASE_DIR/empty"
      matrix_assert stderr "$CASE_DIR/expected.stderr"
    fi
    matrix_assert fs-equal
    matrix_translate_state
    if [[ "$id" == *-file ]]; then
      matrix_assert custom no-output-files python3 - <<'PY'
from pathlib import Path
assert not Path('rejected.md').exists() and not Path('rejected.txt').exists()
PY
    fi
    matrix_finish
  done
}
