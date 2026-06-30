#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKIP_MESSAGE="SKIP cuda qa: missing KOTOBA_CUDA_MODEL or nvidia-smi"

if [[ -z "${KOTOBA_CUDA_MODEL:-}" || ! -f "${KOTOBA_CUDA_MODEL:-}" ]] || ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
  echo "${SKIP_MESSAGE}"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/kotoba-cuda-smoke.XXXXXX")"

cleanup() {
  rm -rf "${TMP}"
}
trap cleanup EXIT

export XDG_CONFIG_HOME="${TMP}/config"
export XDG_DATA_HOME="${TMP}/data"
export XDG_CACHE_HOME="${TMP}/cache"
export XDG_STATE_HOME="${TMP}/state"

env ZIG_GLOBAL_CACHE_DIR="${ROOT}/.zig-cache/global" zig build -Dcuda=true

BIN="${ROOT}/zig-out/bin/kotoba"

INIT_OUT="${TMP}/init.out"
IMPORT_OUT="${TMP}/import.out"
GPU_LAYERS_OUT="${TMP}/gpu-layers.out"
TRANSLATE_JSON="${TMP}/translate.json"
TRANSLATE_ERR="${TMP}/translate.err"

"${BIN}" init --yes >"${INIT_OUT}"
"${BIN}" models import --id cuda-local --path "${KOTOBA_CUDA_MODEL}" --use >"${IMPORT_OUT}"
"${BIN}" config set gpu_layers -1 >"${GPU_LAYERS_OUT}"

"${BIN}" translate "Hello" --to ja --format json --no-memory --debug \
  >"${TRANSLATE_JSON}" \
  2>"${TRANSLATE_ERR}"

json_out="$(cat "${TRANSLATE_JSON}")"
[[ "${json_out}" == *'"runtime":"embedded"'* ]]
if ! grep -Eq '"translated_text":"([^"\\]|\\.)+"' "${TRANSLATE_JSON}"; then
  echo "cuda qa: translated_text must be nonempty" >&2
  exit 1
fi

if ! grep -Eq 'CUDA|GPU|offload|n_gpu_layers' "${TRANSLATE_ERR}"; then
  echo "cuda qa: missing CUDA debug evidence" >&2
  exit 1
fi

echo "PASS cuda qa: translated with CUDA build"
