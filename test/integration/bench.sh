#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/kotoba-bench-$$"
ITERATIONS=5
WARMUP_ITERATIONS=1

cleanup() {
  rm -rf "${TMP}"
}
trap cleanup EXIT

fail() {
  echo "benchmark validation failed: $*" >&2
  exit 1
}

elapsed_ms() {
  local start_ns="$1"
  local end_ns="$2"
  echo $(((end_ns - start_ns) / 1000000))
}

sha256_text() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

run_case() {
  local name="$1"
  local start_ns
  local end_ns
  local output

  start_ns="$(date +%s%N)"
  case "${name}" in
    direct)
      output="$("${BIN}" translate "Hello" --to ja --no-memory)"
      ;;
    stdin)
      output="$(printf 'Hello from stdin' | "${BIN}" translate --to ja --no-memory)"
      ;;
    markdown)
      rm -f "${markdown_output_file}"
      output="$("${BIN}" translate --file "${markdown_file}" --to ja --format markdown --no-memory)"
      [[ -z "${output}" ]] || fail "markdown file translation should not write translated text to stdout"
      [[ -f "${markdown_output_file}" ]] || fail "markdown translated output file was not created"
      output="$(cat "${markdown_output_file}")"
      rm -f "${markdown_output_file}"
      ;;
    *)
      fail "unknown benchmark case ${name}"
      ;;
  esac
  end_ns="$(date +%s%N)"
  RUN_OUTPUT="${output}"
  RUN_ELAPSED_MS="$(elapsed_ms "${start_ns}" "${end_ns}")"
}

validate_output() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  if [[ "${KOTOBA_BENCH_EXPECT_MISMATCH:-0}" == "1" && "${name}" == "direct" ]]; then
    expected="JA:unexpected"
  fi
  [[ "${actual}" == "${expected}" ]] || fail "${name} translated text mismatch"
}

mkdir -p "${TMP}"

export XDG_CONFIG_HOME="${TMP}/config"
export XDG_DATA_HOME="${TMP}/data"
export XDG_CACHE_HOME="${TMP}/cache"
export XDG_STATE_HOME="${TMP}/state"

env ZIG_GLOBAL_CACHE_DIR="${ROOT}/.zig-cache/global" zig build -Dtest-backend=true >/dev/null

BIN="${ROOT}/zig-out/bin/kotoba"
markdown_file="${TMP}/input.md"
markdown_output_file="${TMP}/input.ja.md"
printf '# Hello\n\nThis is a short markdown paragraph.' >"${markdown_file}"

toy_model="${TMP}/toy-source.gguf"
printf 'toy model bytes' >"${toy_model}"
toy_sum="$(sha256sum "${toy_model}" | awk '{print $1}')"
"${BIN}" init --yes >/dev/null
"${BIN}" models import --id toy --path "${toy_model}" --name "Toy Local" --checksum "${toy_sum}" --use >/dev/null

case_names=(direct stdin markdown)
case_formats=(plain plain markdown)
case_expected=("JA:Hello" "JA:Hello from stdin" $'JA:# Hello\n\nJA:This is a short markdown paragraph.')

for ((i = 0; i < WARMUP_ITERATIONS; i++)); do
  for case_name in "${case_names[@]}"; do
    run_case "${case_name}" >/dev/null
  done
done

total_elapsed=0
min_elapsed=
max_elapsed=0
measured_outputs=()

for ((i = 0; i < ITERATIONS; i++)); do
  for idx in "${!case_names[@]}"; do
    run_case "${case_names[$idx]}"
    validate_output "${case_names[$idx]}" "${RUN_OUTPUT}" "${case_expected[$idx]}"
    measured_outputs+=("${RUN_OUTPUT}")
    total_elapsed=$((total_elapsed + RUN_ELAPSED_MS))
    if [[ -z "${min_elapsed}" || "${RUN_ELAPSED_MS}" -lt "${min_elapsed}" ]]; then
      min_elapsed="${RUN_ELAPSED_MS}"
    fi
    if [[ "${RUN_ELAPSED_MS}" -gt "${max_elapsed}" ]]; then
      max_elapsed="${RUN_ELAPSED_MS}"
    fi
  done
done

measurement_count=$((ITERATIONS * ${#case_names[@]}))
avg_elapsed=$((total_elapsed / measurement_count))
joined_outputs="$(printf '%s\n' "${measured_outputs[@]}")"
checksum="$(printf '%s' "${joined_outputs%$'\n'}" | sha256sum | awk '{print $1}')"

python3 - "$ITERATIONS" "$WARMUP_ITERATIONS" "$total_elapsed" "$min_elapsed" "$max_elapsed" "$avg_elapsed" "$checksum" \
  "${case_names[0]}" "${case_formats[0]}" "$(sha256_text "Hello")" "$(sha256_text "${case_expected[0]}")" \
  "${case_names[1]}" "${case_formats[1]}" "$(sha256_text "Hello from stdin")" "$(sha256_text "${case_expected[1]}")" \
  "${case_names[2]}" "${case_formats[2]}" "$(sha256_file "${markdown_file}")" "$(sha256_text "${case_expected[2]}")" <<'PY'
import json
import sys

iterations = int(sys.argv[1])
warmup_iterations = int(sys.argv[2])
total_elapsed_ms = int(sys.argv[3])
min_elapsed_ms = int(sys.argv[4])
max_elapsed_ms = int(sys.argv[5])
avg_elapsed_ms = int(sys.argv[6])
checksum = sys.argv[7]
values = sys.argv[8:]
inputs = [
    {
        "name": values[index],
        "format": values[index + 1],
        "text_sha256": values[index + 2],
        "translated_sha256": values[index + 3],
    }
    for index in range(0, len(values), 4)
]
payload = {
    "benchmark": "translate",
    "backend": "test",
    "iterations": iterations,
    "warmup_iterations": warmup_iterations,
    "total_elapsed_ms": total_elapsed_ms,
    "min_elapsed_ms": min_elapsed_ms,
    "max_elapsed_ms": max_elapsed_ms,
    "avg_elapsed_ms": avg_elapsed_ms,
    "inputs": inputs,
    "checksum": checksum,
}
print(json.dumps(payload, separators=(",", ":")))
PY
