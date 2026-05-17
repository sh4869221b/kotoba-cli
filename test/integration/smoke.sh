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

"${ROOT}/zig-out/bin/kotoba" config set server_autostart false
[[ "$("${ROOT}/zig-out/bin/kotoba" config get server_autostart)" == "false" ]]
"${ROOT}/zig-out/bin/kotoba" config set server_autostart true
[[ "$("${ROOT}/zig-out/bin/kotoba" config get server_autostart)" == "true" ]]
"${ROOT}/zig-out/bin/kotoba" config set runtime llama_server
[[ "$("${ROOT}/zig-out/bin/kotoba" config get runtime)" == "llama_server" ]]
"${ROOT}/zig-out/bin/kotoba" config set llama_server_path /tmp/fake-llama-server
[[ "$("${ROOT}/zig-out/bin/kotoba" config get llama_server_path)" == "/tmp/fake-llama-server" ]]
"${ROOT}/zig-out/bin/kotoba" config set server_startup_timeout_sec 5
[[ "$("${ROOT}/zig-out/bin/kotoba" config get server_startup_timeout_sec)" == "5" ]]

direct="$("${ROOT}/zig-out/bin/kotoba" translate "Hello" --to ja)"
[[ "${direct}" == "JA:Hello" ]]

stdin_out="$(printf 'Hello from stdin' | "${ROOT}/zig-out/bin/kotoba" translate --to ja --no-memory)"
[[ "${stdin_out}" == "JA:Hello from stdin" ]]

stdin_md="$(printf 'Use `kotoba translate`.' | "${ROOT}/zig-out/bin/kotoba" translate --to ja --format markdown --no-memory)"
[[ "${stdin_md}" == 'JA:Use `kotoba translate`.' ]]

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

"${ROOT}/zig-out/bin/kotoba" config set timeout_sec 1
if "${ROOT}/zig-out/bin/kotoba" translate "Hello remote" --to ja --allow-remote-server --no-memory >/tmp/kotoba-smoke-remote-allow.out 2>/tmp/kotoba-smoke-remote-allow.err; then
  echo "remote allow should not contact an unavailable endpoint successfully" >&2
  exit 1
fi
grep -Eq 'server_unreachable|timeout' /tmp/kotoba-smoke-remote-allow.err

AUTO_TMP="${TMP}/auto"
mkdir -p "${AUTO_TMP}/bin"
ln -s "${ROOT}/test/integration/fake_llama_server.py" "${AUTO_TMP}/bin/llama-server"
touch "${AUTO_TMP}/model.gguf"
export XDG_CONFIG_HOME="${AUTO_TMP}/config"
export XDG_DATA_HOME="${AUTO_TMP}/data"
export XDG_CACHE_HOME="${AUTO_TMP}/cache"
export XDG_STATE_HOME="${AUTO_TMP}/state"
export KOTOBA_FAKE_LLAMA_MARKER="${AUTO_TMP}/spawn.log"
AUTO_PORT="$((PORT + 1))"
AUTO_URL="http://localhost:${AUTO_PORT}/"
PATH="${AUTO_TMP}/bin:${PATH}" "${ROOT}/zig-out/bin/kotoba" init --yes --skip-download --server-url "${AUTO_URL}" --model-path "${AUTO_TMP}/model.gguf" >/tmp/kotoba-smoke-autostart-init.out
grep -q "port=${AUTO_PORT}" "${KOTOBA_FAKE_LLAMA_MARKER}"
"${ROOT}/zig-out/bin/kotoba" config set llama_server_path llama-server

auto_out="$(PATH="${AUTO_TMP}/bin:${PATH}" "${ROOT}/zig-out/bin/kotoba" translate "Autostart" --to ja --no-memory)"
[[ "${auto_out}" == "JA:Autostart" ]]
[[ "$(grep -c "port=${AUTO_PORT}" "${KOTOBA_FAKE_LLAMA_MARKER}")" -ge 2 ]]

ALLOW_LOOPBACK_PORT="$((PORT + 3))"
"${ROOT}/zig-out/bin/kotoba" config set server_url "http://127.0.0.1:${ALLOW_LOOPBACK_PORT}"
allow_loopback_out="$(PATH="${AUTO_TMP}/bin:${PATH}" "${ROOT}/zig-out/bin/kotoba" translate "Allow loopback" --to ja --allow-remote-server --no-memory)"
[[ "${allow_loopback_out}" == "JA:Allow loopback" ]]
grep -q "port=${ALLOW_LOOPBACK_PORT}" "${KOTOBA_FAKE_LLAMA_MARKER}"

CACHE_FILL_PORT="$((PORT + 6))"
"${ROOT}/zig-out/bin/kotoba" config set server_url "http://127.0.0.1:${CACHE_FILL_PORT}"
cache_fill_out="$(PATH="${AUTO_TMP}/bin:${PATH}" "${ROOT}/zig-out/bin/kotoba" translate "Cache only" --to ja)"
[[ "${cache_fill_out}" == "JA:Cache only" ]]
grep -q "port=${CACHE_FILL_PORT}" "${KOTOBA_FAKE_LLAMA_MARKER}"
CACHE_HIT_PORT="$((PORT + 7))"
"${ROOT}/zig-out/bin/kotoba" config set server_url "http://127.0.0.1:${CACHE_HIT_PORT}"
cache_hit_before_count="$(grep -c "port=${CACHE_HIT_PORT}" "${KOTOBA_FAKE_LLAMA_MARKER}" || true)"
cache_hit_out="$(PATH="${AUTO_TMP}/bin:${PATH}" "${ROOT}/zig-out/bin/kotoba" translate "Cache only" --to ja)"
[[ "${cache_hit_out}" == "JA:Cache only" ]]
cache_hit_after_count="$(grep -c "port=${CACHE_HIT_PORT}" "${KOTOBA_FAKE_LLAMA_MARKER}" || true)"
[[ "${cache_hit_before_count}" == "${cache_hit_after_count}" ]]

python3 - "${AUTO_PORT}" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
deadline = time.time() + 5
while time.time() < deadline:
    sock = socket.socket()
    sock.settimeout(0.2)
    try:
        sock.connect(("127.0.0.1", port))
    except OSError:
        sys.exit(0)
    finally:
        sock.close()
    time.sleep(0.1)
print("managed child still listening", file=sys.stderr)
sys.exit(1)
PY

DOCTOR_PORT="$((PORT + 4))"
"${ROOT}/zig-out/bin/kotoba" config set server_url "http://127.0.0.1:${DOCTOR_PORT}"
doctor_before_count="$(grep -c "port=${DOCTOR_PORT}" "${KOTOBA_FAKE_LLAMA_MARKER}" || true)"
PATH="${AUTO_TMP}/bin:${PATH}" "${ROOT}/zig-out/bin/kotoba" doctor >/tmp/kotoba-smoke-doctor-no-start.out
doctor_after_count="$(grep -c "port=${DOCTOR_PORT}" "${KOTOBA_FAKE_LLAMA_MARKER}" || true)"
[[ "${doctor_before_count}" == "${doctor_after_count}" ]]
python3 - "${DOCTOR_PORT}" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
deadline = time.time() + 3
while time.time() < deadline:
    sock = socket.socket()
    sock.settimeout(0.2)
    try:
        sock.connect(("127.0.0.1", port))
    except OSError:
        sys.exit(0)
    finally:
        sock.close()
    time.sleep(0.1)
print("doctor started a server", file=sys.stderr)
sys.exit(1)
PY

"${ROOT}/zig-out/bin/kotoba" config set server_url "${SERVER_URL}"
"${ROOT}/zig-out/bin/kotoba" config set server_autostart true
"${ROOT}/zig-out/bin/kotoba" config set runtime manual
PATH="${AUTO_TMP}/bin:${PATH}" "${ROOT}/zig-out/bin/kotoba" doctor >/tmp/kotoba-smoke-doctor-runtime-manual.out
grep -q 'runtime is not supported for autostart; an already-running server may still be used' /tmp/kotoba-smoke-doctor-runtime-manual.out
"${ROOT}/zig-out/bin/kotoba" config set runtime llama_server

rm -f "${AUTO_TMP}/data/kotoba/memory.sqlite3"
if PATH="${AUTO_TMP}/bin:${PATH}" "${ROOT}/zig-out/bin/kotoba" doctor >/tmp/kotoba-smoke-doctor.out 2>/tmp/kotoba-smoke-doctor.err; then
  echo "doctor should report missing memory without creating it" >&2
  exit 1
fi
grep -q 'memory DB cannot be opened' /tmp/kotoba-smoke-doctor.out
[[ ! -e "${AUTO_TMP}/data/kotoba/memory.sqlite3" ]]

STALL_BIN="${AUTO_TMP}/stall-bin"
mkdir -p "${STALL_BIN}"
cat >"${STALL_BIN}/llama-server" <<'SH'
#!/usr/bin/env bash
exec python3 "${KOTOBA_FAKE_LLAMA_SERVER}" --stall-health "$@"
SH
chmod +x "${STALL_BIN}/llama-server"
export KOTOBA_FAKE_LLAMA_SERVER="${ROOT}/test/integration/fake_llama_server.py"
TIMEOUT_PORT="$((PORT + 5))"
"${ROOT}/zig-out/bin/kotoba" config set server_url "http://127.0.0.1:${TIMEOUT_PORT}"
"${ROOT}/zig-out/bin/kotoba" config set llama_server_path "${STALL_BIN}/llama-server"
"${ROOT}/zig-out/bin/kotoba" config set server_startup_timeout_sec 1
timeout_start="$(date +%s)"
if PATH="${STALL_BIN}:${PATH}" "${ROOT}/zig-out/bin/kotoba" translate "Timeout" --to ja --no-memory >/tmp/kotoba-smoke-timeout.out 2>/tmp/kotoba-smoke-timeout.err; then
  echo "stalled llama-server should time out during startup" >&2
  exit 1
fi
timeout_elapsed="$(($(date +%s) - timeout_start))"
[[ "${timeout_elapsed}" -le 3 ]]
grep -q 'server_startup_timeout' /tmp/kotoba-smoke-timeout.err
grep -q "port=${TIMEOUT_PORT}" "${KOTOBA_FAKE_LLAMA_MARKER}"
python3 - "${TIMEOUT_PORT}" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
deadline = time.time() + 5
while time.time() < deadline:
    sock = socket.socket()
    sock.settimeout(0.2)
    try:
        sock.connect(("127.0.0.1", port))
    except OSError:
        sys.exit(0)
    finally:
        sock.close()
    time.sleep(0.1)
print("timed-out managed child still listening", file=sys.stderr)
sys.exit(1)
PY

"${ROOT}/zig-out/bin/kotoba" config set server_url "http://127.0.0.1:$((PORT + 2))/v1"
"${ROOT}/zig-out/bin/kotoba" config set llama_server_path "${AUTO_TMP}/bin/llama-server"
before_count="$(grep -c "port=$((PORT + 2))" "${KOTOBA_FAKE_LLAMA_MARKER}" || true)"
if "${ROOT}/zig-out/bin/kotoba" translate "Hello" --to ja --no-memory >/tmp/kotoba-smoke-basepath.out 2>/tmp/kotoba-smoke-basepath.err; then
  echo "base-path loopback should not autostart" >&2
  exit 1
fi
grep -q 'server_user_managed_endpoint' /tmp/kotoba-smoke-basepath.err
after_count="$(grep -c "port=$((PORT + 2))" "${KOTOBA_FAKE_LLAMA_MARKER}" || true)"
[[ "${before_count}" == "${after_count}" ]]

echo "smoke ok"
