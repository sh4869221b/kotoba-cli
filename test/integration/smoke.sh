#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/kotoba-smoke-$$"
BENCH_JSON="/tmp/kotoba-smoke-bench.json"

cleanup() {
  rm -rf "${TMP}"
  rm -f "${BENCH_JSON}"
}
trap cleanup EXIT

mkdir -p "${TMP}"

export XDG_CONFIG_HOME="${TMP}/config"
export XDG_DATA_HOME="${TMP}/data"
export XDG_CACHE_HOME="${TMP}/cache"
export XDG_STATE_HOME="${TMP}/state"

env ZIG_GLOBAL_CACHE_DIR="${ROOT}/.zig-cache/global" zig build -Dtest-backend=true

BIN="${ROOT}/zig-out/bin/kotoba"

if rg -n 'curl|findHfFileWithCurl|downloadWithCurl' "${ROOT}/src"; then
  echo "runtime source should not depend on curl" >&2
  exit 1
fi
rg -n 'llama_log_set' "${ROOT}/src/llama.zig" >/tmp/kotoba-smoke-llama-log-set.out
rg -n 'progress_callback' "${ROOT}/src/llama.zig" >/tmp/kotoba-smoke-llama-progress-callback.out

"${BIN}" config list >/tmp/kotoba-smoke-config-list-preinit.out
grep -q '^model_id$' /tmp/kotoba-smoke-config-list-preinit.out

"${BIN}" init --yes >/tmp/kotoba-smoke-init.out
"${BIN}" config list >/tmp/kotoba-smoke-config-list.out
grep -q '^model_id$' /tmp/kotoba-smoke-config-list.out
grep -q '^gpu_layers$' /tmp/kotoba-smoke-config-list.out
grep -q '^context_length$' /tmp/kotoba-smoke-config-list.out
if grep -Eq 'server_url|runtime|server_autostart|llama_server_path|server_startup_timeout_sec' /tmp/kotoba-smoke-config-list.out; then
  echo "config list exposes removed server keys" >&2
  exit 1
fi
"${BIN}" config get gpu_layers >/tmp/kotoba-smoke-gpu-layers-default.out
[[ "$(cat /tmp/kotoba-smoke-gpu-layers-default.out)" == "-1" ]]
"${BIN}" config set gpu_layers 0
"${BIN}" config get gpu_layers >/tmp/kotoba-smoke-gpu-layers-zero.out
[[ "$(cat /tmp/kotoba-smoke-gpu-layers-zero.out)" == "0" ]]
"${BIN}" config set gpu_layers -2
"${BIN}" config get gpu_layers >/tmp/kotoba-smoke-gpu-layers-negative.out
[[ "$(cat /tmp/kotoba-smoke-gpu-layers-negative.out)" == "-2" ]]

if "${BIN}" config set server_url http://127.0.0.1:8080 >/tmp/kotoba-smoke-server-url.out 2>/tmp/kotoba-smoke-server-url.err; then
  echo "removed server_url key should be rejected" >&2
  exit 1
fi
grep -q 'invalid_arguments' /tmp/kotoba-smoke-server-url.err

printf 'toy model bytes' >"${TMP}/toy-source.gguf"
SUM="$(sha256sum "${TMP}/toy-source.gguf" | awk '{print $1}')"
"${BIN}" init --model-id init-local --model-path "${TMP}/toy-source.gguf" --yes >/tmp/kotoba-smoke-init-model.out
"${BIN}" models info init-local >/tmp/kotoba-smoke-init-model-info.out
grep -q '^path: '"${TMP}"'/toy-source.gguf$' /tmp/kotoba-smoke-init-model-info.out

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

"${BIN}" init --model-id init-preserve --model-path "${TMP}/toy-source.gguf" --yes >/tmp/kotoba-smoke-init-preserve.out
"${BIN}" models info init-preserve >/tmp/kotoba-smoke-init-preserve-info.out
grep -q '^path: '"${TMP}"'/toy-source.gguf$' /tmp/kotoba-smoke-init-preserve-info.out
grep -q '^download_url: file://'"${TMP}"'/toy-source.gguf$' /tmp/kotoba-smoke-init-preserve-info.out
grep -q '^checksum: '"${SUM}"'$' /tmp/kotoba-smoke-init-preserve-info.out
grep -q '^quantization: Q4_K_M$' /tmp/kotoba-smoke-init-preserve-info.out
grep -q '^recommended: true$' /tmp/kotoba-smoke-init-preserve-info.out

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

"${BIN}" init --model-id init-download --yes >/tmp/kotoba-smoke-init-download.out
"${BIN}" models verify init-download
grep -q '^model_id = "init-download"$' "${XDG_CONFIG_HOME}/kotoba/config.toml"
grep -q '^model_path = "'"${XDG_DATA_HOME}"'/kotoba/models/init-download.gguf"$' "${XDG_CONFIG_HOME}/kotoba/config.toml"

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

PATH="${NO_CURL_BIN}:${PATH}" "${BIN}" config list >/tmp/kotoba-smoke-no-curl-config.out
PATH="${NO_CURL_BIN}:${PATH}" "${BIN}" models pull no-curl-pull --output "${TMP}/no-curl-file-pull.gguf" >/tmp/kotoba-smoke-no-curl-pull.out
grep -q '^pulled no-curl-pull$' /tmp/kotoba-smoke-no-curl-pull.out

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

if "${BIN}" models pull toy-pull-override --checksum deadbeef >/tmp/kotoba-smoke-pull-bad-checksum.out 2>/tmp/kotoba-smoke-pull-bad-checksum.err; then
  echo "positional pull should apply explicit checksum" >&2
  exit 1
fi
grep -q 'checksum_failed' /tmp/kotoba-smoke-pull-bad-checksum.err
"${BIN}" models pull toy-pull-override --checksum "${SUM}"
"${BIN}" models info toy-pull-override >/tmp/kotoba-smoke-pull-override-info.out
grep -q '^checksum: '"${SUM}"'$' /tmp/kotoba-smoke-pull-override-info.out
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

if "${BIN}" models pull --model-url https://example.invalid/model.gguf --id unchecked >/tmp/kotoba-smoke-unchecked-url.out 2>/tmp/kotoba-smoke-unchecked-url.err; then
  echo "direct HTTPS model-url pull should require checksum" >&2
  exit 1
fi
grep -q 'invalid_arguments' /tmp/kotoba-smoke-unchecked-url.err

"${BIN}" models import --id toy --path "${TMP}/toy-source.gguf" --name "Toy Local" --checksum "${SUM}" --use
printf 'bad model bytes' >"${TMP}/bad-source.gguf"
if "${BIN}" models import --id toy --path "${TMP}/bad-source.gguf" --checksum "${SUM}" >/tmp/kotoba-smoke-bad-import.out 2>/tmp/kotoba-smoke-bad-import.err; then
  echo "checksum mismatch import should fail" >&2
  exit 1
fi
grep -q 'checksum_failed' /tmp/kotoba-smoke-bad-import.err
INSTALLED_SUM="$(sha256sum "${XDG_DATA_HOME}/kotoba/models/toy.gguf" | awk '{print $1}')"
[[ "${INSTALLED_SUM}" == "${SUM}" ]]
"${BIN}" models info toy >/tmp/kotoba-smoke-model-info.out
grep -q '^id: toy$' /tmp/kotoba-smoke-model-info.out
grep -q '^name: Toy Local$' /tmp/kotoba-smoke-model-info.out
"${BIN}" models verify toy
"${BIN}" models verify
"${BIN}" config set model_path "${TMP}/missing-selected.gguf"
if "${BIN}" models verify >/tmp/kotoba-smoke-selected-verify.out 2>/tmp/kotoba-smoke-selected-verify.err; then
  echo "verify without an explicit id should check the selected config path" >&2
  exit 1
fi
grep -q 'model_missing' /tmp/kotoba-smoke-selected-verify.err
"${BIN}" models use toy
"${BIN}" doctor >/tmp/kotoba-smoke-doctor.out
grep -q 'ok: model_registry: selected model is registered' /tmp/kotoba-smoke-doctor.out
grep -q 'ok: model_checksum: configured model checksum matches registry' /tmp/kotoba-smoke-doctor.out
"${BIN}" models list >/tmp/kotoba-smoke-model-list.out
grep -q $'toy\tToy Local\tlocal\tcurrent' /tmp/kotoba-smoke-model-list.out

"${BIN}" translate "Hello" --to ja --no-memory \
  >/tmp/kotoba-smoke-translate-direct.out \
  2>/tmp/kotoba-smoke-translate-direct.err
[[ "$(cat /tmp/kotoba-smoke-translate-direct.out)" == "JA:Hello" ]]
[[ ! -s /tmp/kotoba-smoke-translate-direct.err ]]

printf 'Hello from stdin' | "${BIN}" translate --to ja --no-memory \
  >/tmp/kotoba-smoke-translate-stdin.out \
  2>/tmp/kotoba-smoke-translate-stdin.err
[[ "$(cat /tmp/kotoba-smoke-translate-stdin.out)" == "JA:Hello from stdin" ]]
[[ ! -s /tmp/kotoba-smoke-translate-stdin.err ]]

printf '# Hello\n' | "${BIN}" translate --to ja --format markdown --no-memory \
  >/tmp/kotoba-smoke-translate-markdown.out \
  2>/tmp/kotoba-smoke-translate-markdown.err
[[ "$(cat /tmp/kotoba-smoke-translate-markdown.out)" == "JA:# Hello" ]]
[[ ! -s /tmp/kotoba-smoke-translate-markdown.err ]]

"${BIN}" translate "Hello" --to ja --format json --no-memory \
  >/tmp/kotoba-smoke-translate-json.out \
  2>/tmp/kotoba-smoke-translate-json.err
json_out="$(cat /tmp/kotoba-smoke-translate-json.out)"
[[ "${json_out}" == *'"runtime":"embedded"'* ]]
[[ "${json_out}" == *'"translated_text":"JA:Hello"'* ]]
[[ "${json_out}" != *'"server_url"'* ]]
[[ "${json_out}" != *'"source_text"'* ]]
[[ ! -s /tmp/kotoba-smoke-translate-json.err ]]

"${BIN}" translate "Hello" --to ja --format json --include-source --no-memory \
  >/tmp/kotoba-smoke-translate-json-source.out \
  2>/tmp/kotoba-smoke-translate-json-source.err
json_source_out="$(cat /tmp/kotoba-smoke-translate-json-source.out)"
[[ "${json_source_out}" == *'"source_text":"Hello"'* ]]
[[ ! -s /tmp/kotoba-smoke-translate-json-source.err ]]

if command -v script >/dev/null 2>&1 && script --version >/dev/null 2>&1; then
  script -q -e -c "\"${BIN}\" translate \"Hello\" --to ja --no-memory" /tmp/kotoba-smoke-translate-pty.raw >/dev/null
  tr -d '\r' </tmp/kotoba-smoke-translate-pty.raw | sed '/^$/d; /^Script started /d; /^Script done /d' >/tmp/kotoba-smoke-translate-pty.out
  [[ "$(cat /tmp/kotoba-smoke-translate-pty.out)" == "JA:Hello" ]]
fi

"${BIN}" translate "Hello" --to ja --debug --no-memory \
  >/tmp/kotoba-smoke-translate-debug.out \
  2>/tmp/kotoba-smoke-translate-debug.err
[[ "$(cat /tmp/kotoba-smoke-translate-debug.out)" == "JA:Hello" ]]
grep -q 'diagnostics enabled' /tmp/kotoba-smoke-translate-debug.err

"${BIN}" config set log_level debug
"${BIN}" translate "Hello" --to ja --no-memory \
  >/tmp/kotoba-smoke-translate-config-debug.out \
  2>/tmp/kotoba-smoke-translate-config-debug.err
[[ "$(cat /tmp/kotoba-smoke-translate-config-debug.out)" == "JA:Hello" ]]
grep -q 'diagnostics enabled' /tmp/kotoba-smoke-translate-config-debug.err
"${BIN}" config set log_level warn

if "${BIN}" translate "Hello" --to ja --allow-remote-server >/tmp/kotoba-smoke-remote.out 2>/tmp/kotoba-smoke-remote.err; then
  echo "removed --allow-remote-server option should be rejected" >&2
  exit 1
fi
grep -q 'invalid_arguments' /tmp/kotoba-smoke-remote.err

bash "${ROOT}/test/integration/bench.sh" >"${BENCH_JSON}"
grep -q '"benchmark":"translate"' "${BENCH_JSON}"
grep -q '"backend":"test"' "${BENCH_JSON}"
grep -q '"iterations":5' "${BENCH_JSON}"
grep -q '"warmup_iterations":1' "${BENCH_JSON}"
echo "benchmark assertions ok"

"${BIN}" models use toy
"${BIN}" models remove toy --yes
if "${BIN}" models verify >/tmp/kotoba-smoke-verify-none.out 2>/tmp/kotoba-smoke-verify-none.err; then
  echo "verify without selected model should fail after removal" >&2
  exit 1
fi
grep -q 'model_not_selected' /tmp/kotoba-smoke-verify-none.err

if printf '| a |\n| --- |\n| b |\n' | "${BIN}" translate --to ja --format markdown --no-memory >/tmp/kotoba-smoke-translate-protected-none.out 2>/tmp/kotoba-smoke-translate-protected-none.err; then
  echo "protected-only translate without selected model should fail" >&2
  exit 1
fi
grep -q 'model_not_selected' /tmp/kotoba-smoke-translate-protected-none.err

if "${BIN}" translate "Hello" --to ja --no-memory >/tmp/kotoba-smoke-translate-none.out 2>/tmp/kotoba-smoke-translate-none.err; then
  echo "translate without selected model should fail" >&2
  exit 1
fi
grep -q 'model_not_selected' /tmp/kotoba-smoke-translate-none.err

echo "smoke ok"
