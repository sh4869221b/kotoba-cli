#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
harness_init smoke
harness_build_snapshot test
BENCH_JSON="${TMP}/bench.json"

if rg -n 'curl|findHfFileWithCurl|downloadWithCurl' "${ROOT}/src"; then
  echo "runtime source should not depend on curl" >&2
  exit 1
fi
rg -n 'llama_log_set' "${ROOT}/src/llama.zig" >"${TMP}/llama-log-set.out"
rg -n 'progress_callback' "${ROOT}/src/llama.zig" >"${TMP}/llama-progress-callback.out"

"${BIN}" config list >"${TMP}/config-list-preinit.out"
grep -q '^model_id$' "${TMP}/config-list-preinit.out"

"${BIN}" init --yes >"${TMP}/init.out"
"${BIN}" config list >"${TMP}/config-list.out"
grep -q '^model_id$' "${TMP}/config-list.out"
grep -q '^gpu_layers$' "${TMP}/config-list.out"
grep -q '^context_length$' "${TMP}/config-list.out"
if grep -Eq 'server_url|runtime|server_autostart|llama_server_path|server_startup_timeout_sec' "${TMP}/config-list.out"; then
  echo "config list exposes removed server keys" >&2
  exit 1
fi
"${BIN}" config get gpu_layers >"${TMP}/gpu-layers-default.out"
[[ "$(cat "${TMP}/gpu-layers-default.out")" == "-1" ]]
"${BIN}" config set gpu_layers 0
"${BIN}" config get gpu_layers >"${TMP}/gpu-layers-zero.out"
[[ "$(cat "${TMP}/gpu-layers-zero.out")" == "0" ]]
"${BIN}" config set gpu_layers -2
"${BIN}" config get gpu_layers >"${TMP}/gpu-layers-negative.out"
[[ "$(cat "${TMP}/gpu-layers-negative.out")" == "-2" ]]

if "${BIN}" config set server_url http://127.0.0.1:8080 >"${TMP}/server-url.out" 2>"${TMP}/server-url.err"; then
  echo "removed server_url key should be rejected" >&2
  exit 1
fi
grep -q 'invalid_arguments' "${TMP}/server-url.err"

printf 'toy model bytes' >"${TMP}/toy-source.gguf"
SUM="$(sha256sum "${TMP}/toy-source.gguf" | awk '{print $1}')"
"${BIN}" init --model-id init-local --model-path "${TMP}/toy-source.gguf" --yes >"${TMP}/init-model.out"
"${BIN}" models info init-local >"${TMP}/init-model-info.out"
grep -q '^path: '"${TMP}"'/toy-source.gguf$' "${TMP}/init-model-info.out"

cat >>"${XDG_CONFIG_HOME}/kotoba/models.toml" <<TOML

[[models]]
id = "init-preserve"
name = "Init Preserve"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
quantization = "Q4_K_M"
context_length = 128
size = "tiny"
path = ""
download_url = "file://${TMP}/toy-source.gguf"
checksum = "${SUM}"
license = "test-license"
recommended = true
notes = "Metadata should survive init path updates."
TOML

"${BIN}" init --model-id init-preserve --model-path "${TMP}/toy-source.gguf" --yes >"${TMP}/init-preserve.out"
"${BIN}" models info init-preserve >"${TMP}/init-preserve-info.out"
grep -q '^path: '"${TMP}"'/toy-source.gguf$' "${TMP}/init-preserve-info.out"
grep -q '^download_url: file://'"${TMP}"'/toy-source.gguf$' "${TMP}/init-preserve-info.out"
grep -q '^checksum: '"${SUM}"'$' "${TMP}/init-preserve-info.out"
grep -q '^quantization: Q4_K_M$' "${TMP}/init-preserve-info.out"
grep -q '^recommended: true$' "${TMP}/init-preserve-info.out"

cat >>"${XDG_CONFIG_HOME}/kotoba/models.toml" <<TOML

[[models]]
id = "init-download"
name = "Init Download"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
quantization = "test"
context_length = 128
size = "tiny"
path = ""
download_url = "file://${TMP}/toy-source.gguf"
checksum = "${SUM}"
license = ""
recommended = true
notes = "Smoke-test init downloadable source."
TOML

BIN="${BIN}" TMP="${TMP}" SUM="${SUM}" python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import threading


BIN = os.environ["BIN"]
TMP = Path(os.environ["TMP"])
SUM = os.environ["SUM"]
HINT = "kotoba: init does not download models. Run `kotoba models pull ID --use` first, replacing ID with the model ID, or provide --model-path PATH.\n"
MODEL_MISSING = "kotoba: model_missing: Configured model file does not exist.\n"


class Observer:
    def __init__(self):
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.listener.setblocking(False)
        self.port = self.listener.getsockname()[1]
        self.control_read, self.control_write = socket.socketpair()
        self.connections = 0
        self.failure = None
        self.thread = threading.Thread(target=self._run, name="issue9-observer")
        self.thread.start()

    def _drain(self):
        while True:
            try:
                connection, _ = self.listener.accept()
            except BlockingIOError:
                return
            connection.close()
            self.connections += 1

    def _run(self):
        try:
            while True:
                ready, _, _ = select.select([self.listener, self.control_read], [], [])
                if self.listener in ready:
                    self._drain()
                if self.control_read in ready:
                    self.control_read.recv(1)
                    self._drain()
                    return
        except BaseException as error:
            self.failure = error
        finally:
            self.listener.close()
            self.control_read.close()

    def close(self):
        self.control_write.sendall(b"x")
        self.thread.join(5)
        self.control_write.close()
        assert not self.thread.is_alive(), "observer cleanup timed out"
        assert self.failure is None, self.failure


def env_for(root):
    env = os.environ.copy()
    env.update({
        "HOME": str(root / "home"),
        "XDG_CONFIG_HOME": str(root / "config"),
        "XDG_DATA_HOME": str(root / "data"),
        "XDG_CACHE_HOME": str(root / "cache"),
        "XDG_STATE_HOME": str(root / "state"),
    })
    for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"):
        Path(env[key]).mkdir(parents=True, exist_ok=True)
    return env


def write_registry(root, port):
    root.mkdir(parents=True, exist_ok=True)
    source = root / "toy-source.gguf"
    source.write_bytes(b"toy model bytes")
    assert hashlib.sha256(source.read_bytes()).hexdigest() == SUM
    models_file = root / "config" / "kotoba" / "models.toml"
    models_file.parent.mkdir(parents=True, exist_ok=True)
    (root / "data" / "kotoba" / "models").mkdir(parents=True, exist_ok=True)
    missing = root / "missing.gguf"
    remote = f"https://127.0.0.1:{port}/model.gguf"
    models_file.write_text(f'''[[models]]
id = "boundary-pending"
name = "Boundary pending"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
path = ""
download_url = "{remote}"
checksum = "{SUM}"
recommended = true

[[models]]
id = "boundary-absent-path"
name = "Boundary absent"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
path = "{missing}"
download_url = "{remote}"
checksum = "{SUM}"

[[models]]
id = "boundary-installed"
name = "Boundary installed"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
path = "{source}"
download_url = "{remote}"
checksum = "{SUM}"
''')
    return source, models_file


def log_case_start(name, args, observer):
    print(f"network case {name}: phase=start argv={json.dumps([BIN, *args])} port={observer.port}")


def log_case_complete(name, args, observer, process):
    print(f"network case {name}: phase=complete argv={json.dumps([BIN, *args])} port={observer.port} exit={process.returncode} connections={observer.connections} observer_cleanup=ok")


def assert_connection_count(name, args, observer, expected_connections):
    matches = observer.connections == expected_connections if isinstance(expected_connections, int) else observer.connections >= 1
    if not matches:
        print(f"network case {name}: phase=assertions outcome=failed assertion=connections argv={json.dumps([BIN, *args])} port={observer.port} expected={expected_connections} observed={observer.connections}")
    assert matches, (name, observer.connections)


def log_case_pass(name, args, observer):
    print(f"network case {name}: phase=assertions outcome=passed argv={json.dumps([BIN, *args])} port={observer.port}")


def run_case(name, root, args, expected_exit, expected_connections, stdout=None, stderr_parts=(), reset_registry=True):
    observer = Observer()
    process = None
    log_case_start(name, args, observer)
    try:
        if reset_registry:
            write_registry(root, observer.port)
        process = subprocess.run([BIN, *args], env=env_for(root), capture_output=True, timeout=10)
    except subprocess.TimeoutExpired as error:
        raise AssertionError(f"{name}: subprocess timeout: {error}") from error
    finally:
        observer.close()
    log_case_complete(name, args, observer, process)
    assert_connection_count(name, args, observer, expected_connections)
    assert process.returncode == expected_exit, (name, process.returncode, process.stderr)
    if stdout is not None:
        assert process.stdout == stdout, (name, process.stdout)
    for part in stderr_parts:
        assert part.encode() in process.stderr, (name, process.stderr)
    log_case_pass(name, args, observer)
    return process


fresh = TMP / "boundary-fresh"
env_for(fresh)
for name, args in (
    ("init-pending-yes", ["init", "--model-id", "boundary-pending", "--yes"]),
    ("init-pending", ["init", "--model-id", "boundary-pending"]),
    ("init-absent-path", ["init", "--model-id", "boundary-absent-path", "--yes"]),
):
    observer = Observer()
    log_case_start(name, args, observer)
    try:
        _, models_file = write_registry(fresh, observer.port)
        config_file = fresh / "config" / "kotoba" / "config.toml"
        registry_before = models_file.read_bytes()
        process = subprocess.run([BIN, *args], env=env_for(fresh), capture_output=True, timeout=10)
    finally:
        observer.close()
    log_case_complete(name, args, observer, process)
    assert_connection_count(name, args, observer, 0)
    assert process.returncode == 1 and process.stdout == b"" and process.stderr == (HINT + MODEL_MISSING).encode()
    assert not config_file.exists()
    assert not (fresh / "data" / "kotoba" / "memory.sqlite3").exists()
    assert models_file.read_bytes() == registry_before
    assert not list((fresh / "data" / "kotoba" / "models").glob("*.gguf"))
    assert not list((fresh / "data" / "kotoba" / "models").glob("*.tmp-*"))
    log_case_pass(name, args, observer)

run_case("init-yes", fresh, ["init", "--yes"], 0, 0, b"initialized\n")
run_case("init-installed", fresh, ["init", "--model-id", "boundary-installed", "--yes"], 0, 0, b"initialized\n")
for name, args, output in (
    ("translate", ["translate", "Hello", "--from", "en", "--to", "ja", "--no-memory"], b"JA:Hello\n"),
    ("doctor", ["doctor", "--format", "json"], None),
    ("config", ["config", "get", "model_id"], b"boundary-installed\n"),
    ("glossary", ["glossary", "validate"], None),
    ("memory", ["memory", "status"], None),
):
    process = run_case(name, fresh, args, 0, 0, output)
    if name == "doctor":
        assert json.loads(process.stdout)["ok"] is True
    if name == "glossary":
        assert b"terms: 0\n" in process.stdout and b"hash: " in process.stdout
    if name == "memory":
        assert b"rows: 0\n" in process.stdout

source = fresh / "toy-source.gguf"
run_case("init-explicit-path", fresh, ["init", "--model-id", "boundary-pending", "--model-path", str(source), "--yes"], 0, 0, b"initialized\n")
info = run_case("explicit-metadata", fresh, ["models", "info", "boundary-pending"], 0, 0, reset_registry=False)
assert f"checksum: {SUM}\n".encode() in info.stdout and b"download_url: https://127.0.0.1:" in info.stdout
config_before = (fresh / "config" / "kotoba" / "config.toml").read_bytes()
run_case("init-unknown", fresh, ["init", "--model-id", "no-such-boundary-model", "--yes"], 2, 0, b"", ("invalid_arguments",))
assert (fresh / "config" / "kotoba" / "config.toml").read_bytes() == config_before

existing = TMP / "boundary-existing"
run_case("existing-setup", existing, ["init", "--model-id", "boundary-installed", "--yes"], 0, 0, b"initialized\n")
for name, args in (
    ("existing-pending", ["init", "--model-id", "boundary-pending", "--yes"]),
    ("existing-absent-path", ["init", "--model-id", "boundary-absent-path", "--yes"]),
):
    observer = Observer()
    log_case_start(name, args, observer)
    try:
        _, models_file = write_registry(existing, observer.port)
        config_file = existing / "config" / "kotoba" / "config.toml"
        memory_file = existing / "data" / "kotoba" / "memory.sqlite3"
        config_before = config_file.read_bytes()
        registry_before = models_file.read_bytes()
        memory_before = memory_file.read_bytes()
        process = subprocess.run([BIN, *args], env=env_for(existing), capture_output=True, timeout=10)
    finally:
        observer.close()
    log_case_complete(name, args, observer, process)
    assert_connection_count(name, args, observer, 0)
    assert process.returncode == 1 and process.stdout == b"" and process.stderr == (HINT + MODEL_MISSING).encode()
    assert config_file.read_bytes() == config_before
    assert models_file.read_bytes() == registry_before
    assert memory_file.read_bytes() == memory_before
    assert not list((existing / "data" / "kotoba" / "models").glob("*.gguf"))
    assert not list((existing / "data" / "kotoba" / "models").glob("*.tmp-*"))
    log_case_pass(name, args, observer)

pull_root = TMP / "boundary-pull"
run_case("explicit-pull-positive-control", pull_root, ["models", "pull", "boundary-pending", "--output", str(pull_root / "pull-probe.gguf")], 1, ">=1", b"", ("model_registry_invalid",))
assert not (pull_root / "pull-probe.gguf").exists()
assert not list(pull_root.glob("pull-probe.gguf.tmp-*"))
print("network matrix assertions ok")
PY

cp "${XDG_CONFIG_HOME}/kotoba/config.toml" "${TMP}/init-download-config.before"
cp "${XDG_CONFIG_HOME}/kotoba/models.toml" "${TMP}/init-download-registry.before"
if "${BIN}" init --model-id init-download --yes >"${TMP}/init-download.out" 2>"${TMP}/init-download.err"; then
  echo "init must not acquire a file-source registry model" >&2
  exit 1
fi
test ! -s "${TMP}/init-download.out"
grep -Fx 'kotoba: init does not download models. Run `kotoba models pull ID --use` first, replacing ID with the model ID, or provide --model-path PATH.' "${TMP}/init-download.err"
grep -Fx 'kotoba: model_missing: Configured model file does not exist.' "${TMP}/init-download.err"
cmp "${TMP}/init-download-config.before" "${XDG_CONFIG_HOME}/kotoba/config.toml"
cmp "${TMP}/init-download-registry.before" "${XDG_CONFIG_HOME}/kotoba/models.toml"
test ! -e "${XDG_DATA_HOME}/kotoba/models/init-download.gguf"
if compgen -G "${XDG_DATA_HOME}/kotoba/models/init-download.gguf.tmp-*" >/dev/null; then
  echo "init left a partial init-download model" >&2
  exit 1
fi

cat >>"${XDG_CONFIG_HOME}/kotoba/models.toml" <<TOML

[[models]]
id = "toy-pull"
name = "Toy Pull"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
quantization = "test"
context_length = 128
size = "tiny"
path = ""
download_url = "file://${TMP}/toy-source.gguf"
checksum = "${SUM}"
license = ""
recommended = false
notes = "Smoke-test local pull source."
TOML

"${BIN}" models pull toy-pull --use
"${BIN}" models verify toy-pull

NO_CURL_BIN="${TMP}/no-curl-bin"
mkdir -p "${NO_CURL_BIN}"
cat >"${NO_CURL_BIN}/curl" <<'SH'
#!/usr/bin/env bash
echo "curl must not be called" >&2
exit 127
SH
chmod +x "${NO_CURL_BIN}/curl"

cat >>"${XDG_CONFIG_HOME}/kotoba/models.toml" <<TOML

[[models]]
id = "no-curl-pull"
name = "No Curl Pull"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
quantization = "test"
context_length = 128
size = "tiny"
path = ""
download_url = "file://${TMP}/toy-source.gguf"
checksum = "${SUM}"
license = ""
recommended = false
notes = "Smoke-test local pull without curl."
TOML

PATH="${NO_CURL_BIN}:${PATH}" "${BIN}" config list >"${TMP}/no-curl-config.out"
PATH="${NO_CURL_BIN}:${PATH}" "${BIN}" models pull no-curl-pull --output "${TMP}/no-curl-file-pull.gguf" >"${TMP}/no-curl-pull.out"
grep -q '^pulled no-curl-pull$' "${TMP}/no-curl-pull.out"

"${BIN}" models remove toy-pull --yes
if [[ -e "${XDG_DATA_HOME}/kotoba/models/toy-pull.gguf" ]]; then
  echo "managed model file should be removed" >&2
  exit 1
fi

cat >>"${XDG_CONFIG_HOME}/kotoba/models.toml" <<TOML

[[models]]
id = "toy-pull-override"
name = "Toy Pull Override"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
quantization = "test"
context_length = 128
size = "tiny"
path = ""
download_url = "file://${TMP}/toy-source.gguf"
checksum = ""
license = ""
recommended = false
notes = "Smoke-test positional checksum override."
TOML

if "${BIN}" models pull toy-pull-override --checksum deadbeef >"${TMP}/pull-bad-checksum.out" 2>"${TMP}/pull-bad-checksum.err"; then
  echo "positional pull should apply explicit checksum" >&2
  exit 1
fi
grep -q 'checksum_failed' "${TMP}/pull-bad-checksum.err"
"${BIN}" models pull toy-pull-override --checksum "${SUM}"
"${BIN}" models info toy-pull-override >"${TMP}/pull-override-info.out"
grep -q '^checksum: '"${SUM}"'$' "${TMP}/pull-override-info.out"
"${BIN}" models remove toy-pull-override --yes

shared_model="${XDG_DATA_HOME}/kotoba/models/shared.gguf"
printf 'shared model bytes' >"${shared_model}"
SHARED_SUM="$(sha256sum "${shared_model}" | awk '{print $1}')"
cat >>"${XDG_CONFIG_HOME}/kotoba/models.toml" <<TOML

[[models]]
id = "toy-shared-a"
name = "Toy Shared A"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
quantization = "test"
context_length = 128
size = "tiny"
path = "${shared_model}"
download_url = ""
checksum = "${SHARED_SUM}"
license = ""
recommended = false
notes = "Smoke-test shared managed model path."

[[models]]
id = "toy-shared-b"
name = "Toy Shared B"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
quantization = "test"
context_length = 128
size = "tiny"
path = "${shared_model}"
download_url = ""
checksum = "${SHARED_SUM}"
license = ""
recommended = false
notes = "Smoke-test shared managed model path."
TOML

"${BIN}" models remove toy-shared-a --yes
if [[ ! -e "${shared_model}" ]]; then
  echo "shared managed model file should remain while another registry entry references it" >&2
  exit 1
fi
"${BIN}" models remove toy-shared-b --yes
if [[ -e "${shared_model}" ]]; then
  echo "shared managed model file should be removed after the last registry entry is removed" >&2
  exit 1
fi

cat >>"${XDG_CONFIG_HOME}/kotoba/models.toml" <<TOML

[[models]]
id = "toy-pull"
name = "Toy Pull"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
quantization = "test"
context_length = 128
size = "tiny"
path = ""
download_url = "file://${TMP}/toy-source.gguf"
checksum = "${SUM}"
license = ""
recommended = false
notes = "Smoke-test local pull source."
TOML

custom_output="${TMP}/custom-output.gguf"
"${BIN}" models pull toy-pull --output "${custom_output}"
"${BIN}" models remove toy-pull --yes
if [[ ! -e "${custom_output}" ]]; then
  echo "custom output model file should not be deleted by remove" >&2
  exit 1
fi

cat >>"${XDG_CONFIG_HOME}/kotoba/models.toml" <<TOML

[[models]]
id = "toy-pull"
name = "Toy Pull"
profile = "test"
languages = ["en", "ja"]
format = "gguf"
quantization = "test"
context_length = 128
size = "tiny"
path = ""
download_url = "file://${TMP}/toy-source.gguf"
checksum = "${SUM}"
license = ""
recommended = false
notes = "Smoke-test local pull source."
TOML

traversal_output="${XDG_DATA_HOME}/kotoba/models/../outside.gguf"
"${BIN}" models pull toy-pull --output "${traversal_output}"
"${BIN}" models remove toy-pull --yes
if [[ ! -e "${XDG_DATA_HOME}/kotoba/outside.gguf" ]]; then
  echo "path traversal output model file should not be deleted by remove" >&2
  exit 1
fi

if "${BIN}" models pull --model-url https://example.invalid/model.gguf --id unchecked >"${TMP}/unchecked-url.out" 2>"${TMP}/unchecked-url.err"; then
  echo "direct HTTPS model-url pull should require checksum" >&2
  exit 1
fi
grep -q 'invalid_arguments' "${TMP}/unchecked-url.err"

"${BIN}" models import --id toy --path "${TMP}/toy-source.gguf" --name "Toy Local" --checksum "${SUM}" --use
printf 'bad model bytes' >"${TMP}/bad-source.gguf"
if "${BIN}" models import --id toy --path "${TMP}/bad-source.gguf" --checksum "${SUM}" >"${TMP}/bad-import.out" 2>"${TMP}/bad-import.err"; then
  echo "checksum mismatch import should fail" >&2
  exit 1
fi
grep -q 'checksum_failed' "${TMP}/bad-import.err"
INSTALLED_SUM="$(sha256sum "${XDG_DATA_HOME}/kotoba/models/toy.gguf" | awk '{print $1}')"
[[ "${INSTALLED_SUM}" == "${SUM}" ]]
"${BIN}" models info toy >"${TMP}/model-info.out"
grep -q '^id: toy$' "${TMP}/model-info.out"
grep -q '^name: Toy Local$' "${TMP}/model-info.out"
"${BIN}" models verify toy
"${BIN}" models verify
"${BIN}" config set model_path "${TMP}/missing-selected.gguf"
if "${BIN}" models verify >"${TMP}/selected-verify.out" 2>"${TMP}/selected-verify.err"; then
  echo "verify without an explicit id should check the selected config path" >&2
  exit 1
fi
grep -q 'model_missing' "${TMP}/selected-verify.err"
"${BIN}" models use toy
"${BIN}" doctor >"${TMP}/doctor.out"
grep -q 'ok: model_registry: selected model is registered' "${TMP}/doctor.out"
grep -q 'ok: model_checksum: configured model checksum matches registry' "${TMP}/doctor.out"
"${BIN}" models list >"${TMP}/model-list.out"
grep -q $'toy\tToy Local\tlocal\tcurrent' "${TMP}/model-list.out"

"${BIN}" translate "Hello" --from en --to ja --no-memory \
  >"${TMP}/translate-direct.out" \
  2>"${TMP}/translate-direct.err"
[[ "$(cat "${TMP}/translate-direct.out")" == "JA:Hello" ]]
[[ ! -s "${TMP}/translate-direct.err" ]]

printf 'Hello from stdin' | "${BIN}" translate --to ja --no-memory \
  >"${TMP}/translate-stdin.out" \
  2>"${TMP}/translate-stdin.err"
[[ "$(cat "${TMP}/translate-stdin.out")" == "JA:Hello from stdin" ]]
[[ ! -s "${TMP}/translate-stdin.err" ]]

printf 'First\nText:\nLast' | "${BIN}" translate --from en --to ja --no-memory \
  >"${TMP}/translate-literal-marker.out" \
  2>"${TMP}/translate-literal-marker.err"
[[ "$(cat "${TMP}/translate-literal-marker.out")" == $'JA:First\nText:\nLast' ]]
[[ ! -s "${TMP}/translate-literal-marker.err" ]]

"${BIN}" translate "こんにちは" --from ja --to en --no-memory \
  >"${TMP}/translate-ja-en.out" \
  2>"${TMP}/translate-ja-en.err"
[[ "$(cat "${TMP}/translate-ja-en.out")" == "EN:こんにちは" ]]
[[ ! -s "${TMP}/translate-ja-en.err" ]]

printf '# Hello\n' | "${BIN}" translate --to ja --format markdown --no-memory \
  >"${TMP}/translate-markdown.out" \
  2>"${TMP}/translate-markdown.err"
[[ "$(cat "${TMP}/translate-markdown.out")" == "JA:# Hello" ]]
[[ ! -s "${TMP}/translate-markdown.err" ]]

"${BIN}" translate "Hello" --from en --to ja --format json --no-memory \
  >"${TMP}/translate-json.out" \
  2>"${TMP}/translate-json.err"
json_out="$(cat "${TMP}/translate-json.out")"
[[ "${json_out}" == *'"runtime":"embedded"'* ]]
[[ "${json_out}" == *'"translated_text":"JA:Hello"'* ]]
[[ "${json_out}" != *'"server_url"'* ]]
[[ "${json_out}" != *'"source_text"'* ]]
[[ ! -s "${TMP}/translate-json.err" ]]

"${BIN}" translate "こんにちは" --from ja --to en --format json --no-memory \
  >"${TMP}/translate-ja-en-json.out" \
  2>"${TMP}/translate-ja-en-json.err"
python3 - "${TMP}/translate-ja-en-json.out" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["source_lang"] == "ja"
assert payload["target_lang"] == "en"
assert payload["translated_text"] == "EN:こんにちは"
PY
[[ ! -s "${TMP}/translate-ja-en-json.err" ]]

memory_source="task-6-memory-${RANDOM}-${RANDOM}"
"${BIN}" translate "${memory_source}" --from en --to ja --format json \
  >"${TMP}/translate-memory-first.json" \
  2>"${TMP}/translate-memory-first.err"
"${BIN}" translate "${memory_source}" --from en --to ja --format json \
  >"${TMP}/translate-memory-second.json" \
  2>"${TMP}/translate-memory-second.err"
python3 - "${memory_source}" "${TMP}/translate-memory-first.json" "${TMP}/translate-memory-second.json" <<'PY'
import json
import sys

source, first_path, second_path = sys.argv[1:]
first = json.load(open(first_path, encoding="utf-8"))
second = json.load(open(second_path, encoding="utf-8"))
for payload in (first, second):
    assert payload["source_lang"] == "en"
    assert payload["target_lang"] == "ja"
    assert payload["translated_text"] == f"JA:{source}"
assert first["cache_status"] == "none"
assert first["cached"] is False
assert second["cache_status"] == "full"
assert second["cached"] is True
PY
[[ ! -s "${TMP}/translate-memory-first.err" ]]
[[ ! -s "${TMP}/translate-memory-second.err" ]]

"${BIN}" translate "Hello" --to ja --format json --include-source --no-memory \
  >"${TMP}/translate-json-source.out" \
  2>"${TMP}/translate-json-source.err"
json_source_out="$(cat "${TMP}/translate-json-source.out")"
[[ "${json_source_out}" == *'"source_text":"Hello"'* ]]
[[ ! -s "${TMP}/translate-json-source.err" ]]

if command -v script >/dev/null 2>&1 && script --version >/dev/null 2>&1; then
  KOTOBA_PTY_BIN="${BIN}" script -q -e -c 'exec "$KOTOBA_PTY_BIN" translate "Hello" --to ja --no-memory' "${TMP}/translate-pty.raw" >/dev/null
  tr -d '\r' <"${TMP}/translate-pty.raw" | sed '/^$/d; /^Script started /d; /^Script done /d' >"${TMP}/translate-pty.out"
  [[ "$(cat "${TMP}/translate-pty.out")" == "JA:Hello" ]]
fi

"${BIN}" translate "Hello" --to ja --debug --no-memory \
  >"${TMP}/translate-debug.out" \
  2>"${TMP}/translate-debug.err"
[[ "$(cat "${TMP}/translate-debug.out")" == "JA:Hello" ]]
grep -q 'diagnostics enabled' "${TMP}/translate-debug.err"

"${BIN}" config set log_level debug
"${BIN}" translate "Hello" --to ja --no-memory \
  >"${TMP}/translate-config-debug.out" \
  2>"${TMP}/translate-config-debug.err"
[[ "$(cat "${TMP}/translate-config-debug.out")" == "JA:Hello" ]]
grep -q 'diagnostics enabled' "${TMP}/translate-config-debug.err"
"${BIN}" config set log_level warn

if "${BIN}" translate "Hello" --to ja --allow-remote-server >"${TMP}/remote.out" 2>"${TMP}/remote.err"; then
  echo "removed --allow-remote-server option should be rejected" >&2
  exit 1
fi
grep -q 'invalid_arguments' "${TMP}/remote.err"

bash "${ROOT}/test/integration/bench.sh" >"${BENCH_JSON}"
grep -q '"benchmark":"translate"' "${BENCH_JSON}"
grep -q '"backend":"test"' "${BENCH_JSON}"
grep -q '"iterations":5' "${BENCH_JSON}"
grep -q '"warmup_iterations":1' "${BENCH_JSON}"
echo "benchmark assertions ok"

"${BIN}" models use toy
"${BIN}" models remove toy --yes
if "${BIN}" models verify >"${TMP}/verify-none.out" 2>"${TMP}/verify-none.err"; then
  echo "verify without selected model should fail after removal" >&2
  exit 1
fi
grep -q 'model_not_selected' "${TMP}/verify-none.err"

if printf '| a |\n| --- |\n| b |\n' | "${BIN}" translate --to ja --format markdown --no-memory >"${TMP}/translate-protected-none.out" 2>"${TMP}/translate-protected-none.err"; then
  echo "protected-only translate without selected model should fail" >&2
  exit 1
fi
grep -q 'model_not_selected' "${TMP}/translate-protected-none.err"

if "${BIN}" translate "Hello" --to ja --no-memory >"${TMP}/translate-none.out" 2>"${TMP}/translate-none.err"; then
  echo "translate without selected model should fail" >&2
  exit 1
fi
grep -q 'model_not_selected' "${TMP}/translate-none.err"

echo "smoke ok"
