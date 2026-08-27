#!/usr/bin/env bash
set -euo pipefail

commands_fixture() {
  mkdir -p "$XDG_DATA_HOME/kotoba/models"
  printf 'synthetic command matrix model\n' >"$XDG_DATA_HOME/kotoba/models/fixture.gguf"
  matrix_setup init --model-id fixture --model-path "$XDG_DATA_HOME/kotoba/models/fixture.gguf" --yes
  python3 - <<'PY'
import hashlib, json, os
from pathlib import Path
root = Path(os.environ['CASE_ROOT'])
model = root / 'data/kotoba/models/fixture.gguf'
entry = dict(id='fixture', name='Fixture', profile='local', languages=['en', 'ja'], format='gguf',
             quantization='', context_length=0, size='', path=str(model), download_url='', source_url='',
             checksum=hashlib.sha256(b'synthetic command matrix model\n').hexdigest(), license='', recommended=False, notes='Fixture.')
(root / 'config/kotoba/models.toml').write_text('[[models]]\n' + ''.join(f'{k} = {json.dumps(v)}\n' for k,v in entry.items()))
PY
}

commands_streams() {
  local status="$1" stdout="$2" stderr="${3:-}"
  printf '%s' "$stdout" >"$CASE_DIR/expected.stdout"
  printf '%s' "$stderr" >"$CASE_DIR/expected.stderr"
  matrix_assert status "$status"
  matrix_assert stdout "$CASE_DIR/expected.stdout"
  matrix_assert stderr "$CASE_DIR/expected.stderr"
}

commands_unchanged() {
  matrix_assert fs-equal
  matrix_assert db-equal
  matrix_finish
}

commands_error() {
  local code="${1:-invalid_arguments}" message='Invalid arguments.' status=1
  case "$code" in
    invalid_arguments) status=2 ;;
    not_initialized) message='Kotoba is not initialized. Run `kotoba init`.' ;;
    model_missing) message='Configured model file does not exist.' ;;
    model_not_selected) message='No model is selected. Run `kotoba models import --use` or `kotoba models pull --use`.' ;;
    unsupported_language_pair) message='Only en -> ja and ja -> en are supported.' ;;
    glossary_invalid) message='glossary.toml is invalid.' ;;
    *) return 2 ;;
  esac
  commands_streams "$status" '' "kotoba: $code: $message"$'\n'
}

commands_state() {
  matrix_assert custom state python3 - "$CASE_DIR" "$1" "$2" "$3" "${4:-same}" "$commands_umask" <<'PY'
import json, os, tomllib
from pathlib import Path
import sys
directory = Path(sys.argv[1])
created, changed, deleted = (set(filter(None, s.split(','))) for s in sys.argv[2:5])
before, after = ({e['path']: e for e in json.loads((directory / f'fs-{phase}.json').read_text())} for phase in ('before', 'after'))
assert after.keys() - before.keys() == created, ('created', after.keys() - before.keys(), created)
assert before.keys() - after.keys() == deleted, ('deleted', before.keys() - after.keys(), deleted)
actual_changed = {p for p in before.keys() & after.keys() if before[p] != after[p]}
assert actual_changed == changed, ('changed', actual_changed, changed)
for path in changed:
    assert before[path]['type'] == after[path]['type'] == 'file'
    assert before[path]['mode'] == after[path]['mode']
for path in created:
    entry = after[path]
    assert entry['type'] == ('file' if path.endswith(('.toml', '.sqlite3', '.gguf')) else 'directory')
    assert entry['mode'] == ((0o666 if entry['type'] == 'file' else 0o777) & ~int(sys.argv[6], 8))
db_before, db_after = (json.loads((directory / f'db-{phase}.json').read_text()) for phase in ('before', 'after'))
mode = sys.argv[5]
columns = ['source_hash','source_text','translated_text','source_lang','target_lang','mode','model_id','glossary_hash','created_at','updated_at','hit_count']
if mode == 'same':
    assert db_before == db_after
else:
    assert db_after == dict(status='readable', columns=columns, rows=[], row_count=0)
    if mode == 'create':
        assert db_before == {'status':'absent'}
    elif mode == 'clear':
        assert db_before == dict(status='readable', columns=columns, rows=[['seed','Hello','JA:Hello','en','ja','default','fixture','0',1,1,0]], row_count=1)
    else:
        raise AssertionError(mode)
root = Path(os.environ['CASE_ROOT'])
for name in ('config', 'models', 'glossary'):
    expected = directory / f'expected-{name}.json'
    if expected.exists():
        actual = tomllib.loads((root / f'config/kotoba/{name}.toml').read_text())
        assert actual == json.loads(expected.read_text()), (name, actual)
PY
  matrix_finish
}

# Read fixture input before the measured command; do not learn goldens from its result.
commands_expect_mutation() {
  python3 - "$1" <<'PY'
import json, os, sys, tomllib
from pathlib import Path
root, directory = Path(os.environ['CASE_ROOT']), Path(os.environ['CASE_DIR'])
config = tomllib.loads((root / 'config/kotoba/config.toml').read_text())
models = tomllib.loads((root / 'config/kotoba/models.toml').read_text())
operation = sys.argv[1]
if operation == 'config':
    config['gpu_layers'] = 0
elif operation == 'use':
    config.update(model_id='fixture', model_path=str(root / 'data/kotoba/models/fixture.gguf'))
elif operation == 'remove':
    config.update(model_id='', model_path='')
    models = {}
elif operation in ('import', 'pull'):
    model_id = 'imported' if operation == 'import' else 'pulled'
    path = str(root / f'data/kotoba/models/{model_id}.gguf')
    config.update(model_id=model_id, model_path=path)
    if operation == 'import':
        entry = dict(models['models'][0])
        entry.update(id=model_id, name=model_id, path=path, notes='Imported local GGUF model.')
        models['models'].append(entry)
    else:
        models['models'][1]['path'] = path
else:
    raise AssertionError(operation)
(directory / 'expected-config.json').write_text(json.dumps(config))
(directory / 'expected-models.json').write_text(json.dumps(models))
PY
}

commands_default_expectations() {
  python3 - "${1:-models}" <<'PY'
import json, os
from pathlib import Path
import sys
directory = Path(os.environ['CASE_DIR'])
custom = dict(id='custom', name='Custom local GGUF model', profile='custom', languages=['en','ja'],
              format='gguf', quantization='', context_length=4096, size='', download_url='', checksum='',
              license='', recommended=False, notes='Set model_path during init or config.')
light = dict(id='example-light', name='Example Light Model Placeholder', profile='default', languages=['en','ja'],
             format='gguf', quantization='Q4_K_M', context_length=4096, size='small', download_url='', checksum='',
             license='', recommended=True, notes='Placeholder only. Add a verified download_url and checksum before use.')
(directory / 'expected-models.json').write_text(json.dumps({'models':[custom,light]}))
if sys.argv[1] == 'init':
    config = dict(default_source_lang='', default_target_lang='ja', default_mode='default', default_output='plain',
                  model_id='', model_path='', gpu_layers=-1, context_length=4096, threads=0, max_tokens=1024,
                  temperature=0.2, timeout_sec=120, memory_enabled=True, glossary_enabled=True, privacy_mode=True, log_level='warn')
    (directory / 'expected-config.json').write_text(json.dumps(config))
    (directory / 'expected-glossary.json').write_text('{}')
PY
}

commands_doctor_expectation() {
  python3 - "$1" "$2" <<'PY'
import json, os, sys
from pathlib import Path
variant, output = sys.argv[1:]
checks = []
def add(name, message, status='ok', code=''):
    checks.append(dict(name=name, status=status, code=code, message=message))
if variant == 'absent':
    add('config','config.toml is missing or invalid','error','not_initialized')
    add('models','models.toml is missing or invalid','error','models_invalid')
else:
    for name, message in [('config','config.toml is readable'), ('llama_cpp','embedded llama.cpp runtime is linked'),
        ('models','models.toml is readable'), ('selected_model','model is selected'), ('model_file','configured model_path exists'),
        ('model_registry','selected model is registered'), ('model_checksum','configured model checksum matches registry')]:
        add(name,message)
    if variant == 'missing-db':
        add('memory','memory DB cannot be opened','error','sqlite_failed')
    else:
        for name, message in [('memory','memory DB is readable'),('glossary','glossary.toml is readable'),('privacy','privacy_mode is enabled')]:
            add(name,message)
value = dict(ok=variant == 'ready', checks=checks)
directory = Path(os.environ['CASE_DIR'])
(directory / 'expected-doctor.json').write_text(json.dumps(value))
text = json.dumps(value, separators=(',',':'))+'\n' if output == 'json' else ''.join(f"{c['status']}: {c['name']}: {c['message']}\n" for c in checks)
(directory / 'expected.stdout').write_text(text)
PY
}

matrix_commands() {
  local id variant format expected status base_dirs commands_umask
  commands_umask="$(umask)"
  base_dirs='config/kotoba,data/kotoba,data/kotoba/models,cache/kotoba,state/kotoba'
  for id in version version-extra-characterization; do
    matrix_case "commands-$id"
    if [[ "$id" == version ]]; then matrix_run version; else matrix_run version extra; fi
    commands_streams 0 $'kotoba 0.0.1\n'
    commands_unchanged
  done
  for id in top-missing top-invalid init-invalid init-missing-value models-missing-subcommand memory-missing-subcommand; do
    matrix_case "commands-$id"
    case "$id" in
      top-missing) matrix_run ;;
      top-invalid) matrix_run bogus ;;
      init-invalid) matrix_run init bogus ;;
      init-missing-value) matrix_run init --model-id ;;
      models-missing-subcommand) matrix_run models ;;
      memory-missing-subcommand) matrix_run memory ;;
    esac
    commands_error
    commands_unchanged
  done

  matrix_case commands-init-yes
  commands_default_expectations init
  matrix_run init --yes
  commands_streams 0 $'initialized\n'
  commands_state "$base_dirs,config/kotoba/config.toml,config/kotoba/models.toml,config/kotoba/glossary.toml,data/kotoba/memory.sqlite3" '' '' create

  matrix_case commands-init-remote-rejected
  commands_fixture
  cat >"$XDG_CONFIG_HOME/kotoba/models.toml" <<'TOML'
[[models]]
id = "remote"
download_url = "https://models.example.invalid/model.gguf"
checksum = "unused"
TOML
  matrix_run init --model-id remote --yes
  commands_streams 1 '' $'kotoba: init does not download models. Run `kotoba models pull ID --use` first, replacing ID with the model ID, or provide --model-path PATH.\nkotoba: model_missing: Configured model file does not exist.\n'
  commands_unchanged

  expected=$'default_source_lang\ndefault_target_lang\ndefault_mode\ndefault_output\nmodel_id\nmodel_path\ngpu_layers\ncontext_length\nthreads\nmax_tokens\ntemperature\ntimeout_sec\nmemory_enabled\nglossary_enabled\nprivacy_mode\nlog_level\n'
  for variant in ready absent; do
    matrix_case "commands-config-list-$variant"
    if [[ "$variant" == ready ]]; then commands_fixture; fi
    matrix_run config list
    commands_streams 0 "$expected"
    commands_unchanged
  done
  for variant in default updated; do
    matrix_case "commands-config-get-$variant"
    commands_fixture
    expected=$'-1\n'
    if [[ "$variant" == updated ]]; then matrix_setup config set gpu_layers 0; expected=$'0\n'; fi
    matrix_run config get gpu_layers
    commands_streams 0 "$expected"
    commands_unchanged
  done
  matrix_case commands-config-set
  commands_fixture
  commands_expect_mutation config
  matrix_run config set gpu_layers 0
  commands_streams 0 ''
  commands_state '' config/kotoba/config.toml ''
  matrix_case commands-config-get-absent
  matrix_run config get gpu_layers
  commands_error not_initialized
  commands_unchanged

  for id in config-invalid config-get-arity config-set-arity config-list-arity models-info-arity models-import-arity models-pull-arity models-use-arity models-verify-arity models-remove-arity glossary-invalid glossary-arity doctor-invalid doctor-arity; do
    matrix_case "commands-$id"
    commands_fixture
    case "$id" in
      config-invalid) matrix_run config bogus ;;
      config-get-arity) matrix_run config get ;;
      config-set-arity) matrix_run config set gpu_layers ;;
      config-list-arity) matrix_run config list extra ;;
      models-info-arity) matrix_run models info ;;
      models-import-arity) matrix_run models import --id ;;
      models-pull-arity) matrix_run models pull ;;
      models-use-arity) matrix_run models use ;;
      models-verify-arity) matrix_run models verify a b ;;
      models-remove-arity) matrix_run models remove fixture ;;
      glossary-invalid) matrix_run glossary bogus ;;
      glossary-arity) matrix_run glossary validate extra ;;
      doctor-invalid) matrix_run doctor bogus ;;
      doctor-arity) matrix_run doctor --format ;;
    esac
    commands_error
    commands_unchanged
  done
  for id in models-list-absent models-invalid-absent models-list-arity-absent; do
    matrix_case "commands-$id"
    commands_default_expectations
    case "$id" in
      models-list-absent) matrix_run models list; commands_streams 0 $'custom\tCustom local GGUF model\tcustom\nexample-light\tExample Light Model Placeholder\tdefault\trecommended\n' ;;
      models-invalid-absent) matrix_run models bogus; commands_error ;;
      models-list-arity-absent) matrix_run models list extra; commands_error ;;
    esac
    commands_state "$base_dirs,config/kotoba/models.toml" '' ''
  done
  matrix_case commands-models-list
  commands_fixture
  matrix_run models list
  commands_streams 0 $'fixture\tFixture\tlocal\tcurrent\n'
  commands_unchanged
  matrix_case commands-models-info
  commands_fixture
  python3 - <<'PY'
import hashlib, os
from pathlib import Path
path = str(Path(os.environ['CASE_ROOT']) / 'data/kotoba/models/fixture.gguf')
checksum = hashlib.sha256(b'synthetic command matrix model\n').hexdigest()
Path(os.environ['CASE_DIR'],'expected.stdout').write_text(f'id: fixture\nname: Fixture\nprofile: local\nformat: gguf\nquantization: \ncontext_length: 0\npath: {path}\ndownload_url: \nsource_url: \nchecksum: {checksum}\nlicense: \nrecommended: false\nnotes: Fixture.\n')
PY
  matrix_run models info fixture
  matrix_assert status 0
  matrix_assert stdout "$CASE_DIR/expected.stdout"
  matrix_assert stderr "$CASE_STDIN"
  commands_unchanged

  for variant in import pull use remove; do
    matrix_case "commands-models-$variant"
    commands_fixture
    if [[ "$variant" == use ]]; then matrix_setup config set model_id other; fi
    if [[ "$variant" == pull ]]; then
      python3 - <<'PY'
import json, os, tomllib
from pathlib import Path
path = Path(os.environ['XDG_CONFIG_HOME']) / 'kotoba/models.toml'
entry = dict(tomllib.loads(path.read_text())['models'][0])
entry.update(id='pulled', name='Pulled', path='', download_url='file://' + entry['path'])
with path.open('a') as stream:
    stream.write('\n[[models]]\n' + ''.join(f'{k} = {json.dumps(v)}\n' for k,v in entry.items()))
PY
    fi
    commands_expect_mutation "$variant"
    case "$variant" in
      import)
        local checksum
        checksum="$(sha256sum "$XDG_DATA_HOME/kotoba/models/fixture.gguf")"; checksum="${checksum%% *}"
        matrix_run models import --id imported --path "$XDG_DATA_HOME/kotoba/models/fixture.gguf" --checksum "$checksum" --use
        commands_streams 0 $'imported imported\n'
        matrix_assert file "$XDG_DATA_HOME/kotoba/models/imported.gguf" "$XDG_DATA_HOME/kotoba/models/fixture.gguf"
        commands_state data/kotoba/models/imported.gguf config/kotoba/config.toml,config/kotoba/models.toml '' ;;
      pull)
        matrix_run models pull pulled --use
        commands_streams 0 $'pulled pulled\n'
        matrix_assert file "$XDG_DATA_HOME/kotoba/models/pulled.gguf" "$XDG_DATA_HOME/kotoba/models/fixture.gguf"
        commands_state data/kotoba/models/pulled.gguf config/kotoba/config.toml,config/kotoba/models.toml '' ;;
      use)
        matrix_run models use fixture
        commands_streams 0 $'using fixture\n'
        commands_state '' config/kotoba/config.toml '' ;;
      remove)
        matrix_run models remove fixture --yes
        commands_streams 0 $'removed fixture\n'
        commands_state '' config/kotoba/config.toml,config/kotoba/models.toml data/kotoba/models/fixture.gguf ;;
    esac
  done
  for variant in explicit selected; do
    matrix_case "commands-models-verify-$variant"
    commands_fixture
    if [[ "$variant" == explicit ]]; then matrix_run models verify fixture; else matrix_run models verify; fi
    commands_streams 0 $'verified fixture\n'
    commands_unchanged
  done

  for variant in ready absent missing-db; do
    for format in human json; do
      matrix_case "commands-doctor-$variant-$format"
      if [[ "$variant" != absent ]]; then commands_fixture; fi
      if [[ "$variant" == missing-db ]]; then rm "$CASE_DB"; fi
      commands_doctor_expectation "$variant" "$format"
      if [[ "$format" == json ]]; then matrix_run doctor --format json; else matrix_run doctor; fi
      status=1; if [[ "$variant" == ready ]]; then status=0; fi
      matrix_assert status "$status"
      matrix_assert stdout "$CASE_DIR/expected.stdout"
      matrix_assert stderr "$CASE_STDIN"
      if [[ "$format" == json ]]; then
        matrix_assert json doctor
        matrix_assert json-values "$(cat "$CASE_DIR/expected-doctor.json")"
      fi
      commands_unchanged
    done
  done
  for id in doctor-invalid-json invalid-json; do
    matrix_case "commands-$id"
    commands_fixture
    if [[ "$id" == doctor-invalid-json ]]; then matrix_run doctor --format json extra
    else matrix_run translate Hello --to ja --no-memory --format json --bogus; fi
    commands_streams 2 $'{"error":{"code":"invalid_arguments","message":"Invalid arguments."}}\n'
    matrix_assert json error
    matrix_assert json-values '{"error":{"code":"invalid_arguments","message":"Invalid arguments."}}'
    commands_unchanged
  done

  for variant in ready absent invalid-data; do
    matrix_case "commands-glossary-$variant"
    if [[ "$variant" != absent ]]; then commands_fixture; fi
    if [[ "$variant" == invalid-data ]]; then printf '[[terms]]\nmode = "bogus"\n' >"$XDG_CONFIG_HOME/kotoba/glossary.toml"; fi
    matrix_run glossary validate
    if [[ "$variant" == invalid-data ]]; then commands_error glossary_invalid
    else
      # Zig std/hash/wyhash.zig seed=0, input="" test vector; never captured CLI output.
      commands_streams 0 $'terms: 0\nhash: 409638ee2bde459\n'
    fi
    commands_unchanged
  done
  for variant in status clear status-extra; do
    matrix_case "commands-memory-$variant"
    commands_fixture
    python3 - <<'PY'
import os, sqlite3
with sqlite3.connect(os.environ['CASE_DB']) as db:
    db.execute('INSERT INTO translations VALUES (?,?,?,?,?,?,?,?,?,?,?)', ('seed','Hello','JA:Hello','en','ja','default','fixture','0',1,1,0))
PY
    case "$variant" in
      clear)
        matrix_run memory clear --yes
        commands_streams 0 ''
        commands_state '' data/kotoba/memory.sqlite3 '' clear ;;
      *)
        if [[ "$variant" == status ]]; then matrix_run memory status; else matrix_run memory status extra; fi
        commands_streams 0 "path: $CASE_DB"$'\nrows: 1\n'
        commands_unchanged ;;
    esac
  done
  for variant in status invalid clear-arity; do
    matrix_case "commands-memory-$variant-absent-db"
    mkdir -p "$XDG_DATA_HOME/kotoba"
    case "$variant" in
      status) matrix_run memory status; commands_streams 0 "path: $CASE_DB"$'\nrows: 0\n' ;;
      invalid) matrix_run memory bogus; commands_error ;;
      clear-arity) matrix_run memory clear; commands_error ;;
    esac
    commands_state data/kotoba/memory.sqlite3 '' '' create
  done
  for variant in invalid-human conflicting-inputs unsupported-pair absent-config no-selection unknown-token cpu-model-missing; do
    id="commands-translate-$variant"
    if [[ "$variant" == cpu-model-missing ]]; then matrix_case "$id" cpu; else matrix_case "$id"; fi
    if [[ "$variant" != absent-config ]]; then commands_fixture; fi
    case "$variant" in
      invalid-human) matrix_run translate Hello --to ja --no-memory --bogus; commands_error ;;
      conflicting-inputs)
        printf 'Hello\n' >"$CASE_ROOT/work/input.txt"
        matrix_run translate Hello --file "$CASE_ROOT/work/input.txt" --to ja --no-memory
        commands_error ;;
      unsupported-pair) matrix_run translate Hello --from en --to en --no-memory; commands_error unsupported_language_pair ;;
      absent-config) matrix_run translate Hello --to ja --no-memory; commands_error not_initialized ;;
      no-selection)
        matrix_setup config set model_id ''
        matrix_setup config set model_path ''
        matrix_run translate Hello --to ja --no-memory
        commands_error model_not_selected ;;
      unknown-token)
        matrix_run translate --bogus --from en --to ja --no-memory
        commands_streams 0 $'JA:--bogus\n' ;;
      cpu-model-missing)
        matrix_setup config set model_path "$CASE_ROOT/work/missing.gguf"
        matrix_run translate Hello --to ja --no-memory
        commands_error model_missing ;;
    esac
    commands_unchanged
  done
}
