#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PORT="${KOTOBA_SMOKE_PORT:-18080}"
SERVER_URL="http://127.0.0.1:${PORT}"
TMP="${TMPDIR:-/tmp}/kotoba-smoke-$$"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

mkdir -p "${TMP}"
touch "${TMP}/model.gguf"

python3 "${ROOT}/test/integration/fake_llama_server.py" "${PORT}" &
SERVER_PID=$!
sleep 0.3

export XDG_CONFIG_HOME="${TMP}/config"
export XDG_DATA_HOME="${TMP}/data"
export XDG_CACHE_HOME="${TMP}/cache"
export XDG_STATE_HOME="${TMP}/state"

"${ROOT}/zig-out/bin/kotoba" init --yes --skip-download --server-url "${SERVER_URL}" --model-path "${TMP}/model.gguf" >/tmp/kotoba-smoke-init.out

direct="$("${ROOT}/zig-out/bin/kotoba" translate "Hello" --to ja)"
[[ "${direct}" == "JA:Hello" ]]

stdin_out="$(printf 'Hello from stdin' | "${ROOT}/zig-out/bin/kotoba" translate --to ja --no-memory)"
[[ "${stdin_out}" == "JA:Hello from stdin" ]]

printf 'Hello file' >"${TMP}/input.txt"
txt_out="$("${ROOT}/zig-out/bin/kotoba" translate --file "${TMP}/input.txt" --to ja --format plain)"
[[ "${txt_out}" == "JA:Hello file" ]]

cat >"${TMP}/doc.md" <<'MD'
# Hello

Use `kotoba translate`.

| A | B |
| - | - |
| URL | https://example.com |
MD
"${ROOT}/zig-out/bin/kotoba" translate --file "${TMP}/doc.md" --to ja --overwrite
grep -q '^| A | B |$' "${TMP}/doc.ja.md"
grep -q '`kotoba translate`' "${TMP}/doc.ja.md"

json_out="$("${ROOT}/zig-out/bin/kotoba" translate "Hello" --to ja --format json)"
[[ "${json_out}" == *'"cache_status"'* ]]
[[ "${json_out}" != *'"source_text"'* ]]

"${ROOT}/zig-out/bin/kotoba" config set server_url http://192.0.2.1:8080
if "${ROOT}/zig-out/bin/kotoba" translate "Hello" --to ja >/tmp/kotoba-smoke-remote.out 2>/tmp/kotoba-smoke-remote.err; then
  echo "remote server rejection failed" >&2
  exit 1
fi
grep -q 'server_not_local' /tmp/kotoba-smoke-remote.err

echo "smoke ok"
