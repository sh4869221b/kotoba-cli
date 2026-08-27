#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ROUNDS=3
MAX_ROUNDS=1000
EVIDENCE_DIR=
SELF_TEST=0
EVIDENCE_RUN=
CHILD_TMPDIR=
PARENT_STATE_ROOT=
PARENT_STATE_BEFORE=
PIDS=()
LABELS=()
ROUND_LABELS=()
UNIT_ROOTS=()

invalid_arguments() {
  echo "parallel harness: invalid arguments" >&2
  exit 2
}

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --rounds)
        (( $# >= 2 )) || invalid_arguments
        [[ "$2" =~ ^[1-9][0-9]{0,3}$ ]] || invalid_arguments
        ROUNDS="$2"
        (( ROUNDS <= MAX_ROUNDS )) || invalid_arguments
        shift 2
        ;;
      --evidence-dir)
        (( $# >= 2 )) || invalid_arguments
        [[ "$2" == /* ]] || invalid_arguments
        EVIDENCE_DIR="$2"
        shift 2
        ;;
      --self-test)
        SELF_TEST=1
        shift
        ;;
      *)
        invalid_arguments
        ;;
    esac
  done
  if (( SELF_TEST == 1 )) && { (( ROUNDS != 3 )) || [[ -n "${EVIDENCE_DIR}" ]]; }; then
    invalid_arguments
  fi
}

tree_fingerprint() {
  local tree="$1"
  (
    cd "${tree}"
    find . -printf '%P %y %s\n' | LC_ALL=C sort
    while IFS= read -r -d '' file; do
      sha256sum "${file}"
    done < <(find . -type f -print0 | LC_ALL=C sort -z)
  ) | sha256sum | awk '{print $1}'
}

record_child_statuses() {
  local index pid status aggregate=0
  for index in "${!PIDS[@]}"; do
    pid="${PIDS[$index]}"
    if wait "${pid}"; then
      status=0
    else
      status=$?
    fi
    printf 'round=%s child=%s pid=%s status=%s\n' \
      "${ROUND_LABELS[$index]}" "${LABELS[$index]}" "${pid}" "${status}" \
      | tee "${EVIDENCE_RUN}/round-${ROUND_LABELS[$index]}-${LABELS[$index]}.status"
    (( status == 0 )) || aggregate=1
  done
  PIDS=()
  LABELS=()
  ROUND_LABELS=()
  return "${aggregate}"
}

terminate_and_reap_children() {
  local pid
  for pid in "${PIDS[@]}"; do
    kill -TERM -- "-${pid}" 2>/dev/null || true
  done
  for pid in "${PIDS[@]}"; do
    wait "${pid}" 2>/dev/null || true
  done
  PIDS=()
  LABELS=()
  ROUND_LABELS=()
}

cleanup_owned_child_tmpdir() {
  if [[ -n "${CHILD_TMPDIR}" && -n "${TMP:-}" && "${CHILD_TMPDIR}" == "${TMP}/"* ]]; then
    rm -rf -- "${CHILD_TMPDIR}"
    CHILD_TMPDIR=
  fi
}

parallel_cleanup() {
  local status=$?
  trap - EXIT INT TERM
  terminate_and_reap_children
  cleanup_owned_child_tmpdir
  harness_cleanup || true
  exit "${status}"
}

install_parallel_cleanup_traps() {
  trap parallel_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

start_child() {
  local round="$1"
  local label="$2"
  shift 2
  local prefix="${EVIDENCE_RUN}/round-${round}-${label}"
  local restore_job_control=0
  case "$-" in
    *m*) ;;
    *)
      set -m
      restore_job_control=1
      ;;
  esac
  "$@" >"${prefix}.out" 2>"${prefix}.err" &
  PIDS+=("$!")
  if [[ "${restore_job_control}" == "1" ]]; then
    set +m
  fi
  LABELS+=("${label}")
  ROUND_LABELS+=("${round}")
}

start_unit_child() {
  local round="$1"
  local number="$2"
  local label="unit-${number}"
  local unit_root="${TMP}/units/round-${round}-${label}"
  mkdir -p "${unit_root}/home" "${unit_root}/config" "${unit_root}/data" \
    "${unit_root}/cache" "${unit_root}/state" "${unit_root}/.zig-cache/tmp"
  UNIT_ROOTS+=("${unit_root}")
  start_child "${round}" "${label}" bash -c '
    set -euo pipefail
    unit_root="$1"
    unit_bin="$2"
    cd "${unit_root}"
    exec env \
      HOME="${unit_root}/home" \
      XDG_CONFIG_HOME="${unit_root}/config" \
      XDG_DATA_HOME="${unit_root}/data" \
      XDG_CACHE_HOME="${unit_root}/cache" \
      XDG_STATE_HOME="${unit_root}/state" \
      TMPDIR="${unit_root}/.zig-cache/tmp" \
      ZIG_GLOBAL_CACHE_DIR="${unit_root}/.zig-cache/global" \
      ZIG_LOCAL_CACHE_DIR="${unit_root}/.zig-cache/local" \
      "${unit_bin}"
  ' bash "${unit_root}" "${UNIT_BIN}"
}

start_script_child() {
  local round="$1"
  local label="$2"
  local script_name="$3"
  start_child "${round}" "${label}" bash -c '
    set -euo pipefail
    root="$1"
    parent_state="$2"
    child_tmpdir="$3"
    script_name="$4"
    cd "${root}"
    exec env \
      HOME="${parent_state}/home" \
      XDG_CONFIG_HOME="${parent_state}/config" \
      XDG_DATA_HOME="${parent_state}/data" \
      XDG_CACHE_HOME="${parent_state}/cache" \
      XDG_STATE_HOME="${parent_state}/state" \
      TMPDIR="${child_tmpdir}" \
      bash "${root}/test/integration/${script_name}"
  ' bash "${ROOT}" "${PARENT_STATE_ROOT}" "${CHILD_TMPDIR}" "${script_name}"
}

verify_benchmark_json() {
  local path="$1"
  python3 - "${path}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
assert payload["benchmark"] == "translate"
assert payload["backend"] == "test"
assert payload["iterations"] == 5
assert payload["warmup_iterations"] == 1
PY
}

verify_unit_cleanup() {
  local unit_root
  local status=0
  for unit_root in "${UNIT_ROOTS[@]}"; do
    if find "${unit_root}/.zig-cache/tmp" -mindepth 1 -print -quit | grep -q .; then
      echo "parallel harness: unit temporary files remain in ${unit_root}" >&2
      status=1
    fi
    rm -rf -- "${unit_root}"
  done
  UNIT_ROOTS=()
  return "${status}"
}

verify_parent_state() {
  local after
  after="${EVIDENCE_RUN}/parent-state-after.sha256"
  tree_fingerprint "${PARENT_STATE_ROOT}" >"${after}"
  cmp -s "${PARENT_STATE_BEFORE}" "${after}"
}

verify_child_tmp_cleanup() {
  ! find "${CHILD_TMPDIR}" -mindepth 1 -print -quit | grep -q .
}

self_test_fail() {
  echo "parallel harness self-test failed: $*" >&2
  exit 1
}

run_self_test() {
  local scratch rc early_pid later_pid interrupt_pid_file interrupt_root_file interrupt_root grandchild_pid
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/kotoba-parallel-self-test.XXXXXX")"
  EVIDENCE_RUN="${scratch}/evidence"
  mkdir -p "${EVIDENCE_RUN}"

  start_child self early bash -c 'exit 7'
  early_pid="${PIDS[0]}"
  start_child self later bash -c 'exit 0'
  later_pid="${PIDS[1]}"
  if record_child_statuses; then
    self_test_fail "early status 7 was hidden by a later successful child"
  fi
  grep -qx "round=self child=early pid=${early_pid} status=7" "${EVIDENCE_RUN}/round-self-early.status" \
    || self_test_fail "early child status was not recorded"
  grep -qx "round=self child=later pid=${later_pid} status=0" "${EVIDENCE_RUN}/round-self-later.status" \
    || self_test_fail "later child status was not recorded"
  ! kill -0 "${early_pid}" 2>/dev/null || self_test_fail "early child was not reaped"
  ! kill -0 "${later_pid}" 2>/dev/null || self_test_fail "later child was not reaped"
  echo "parallel harness self-test: status aggregation and reaping ok"

  TMP="${scratch}"
  CHILD_TMPDIR="${scratch}/child-tmp"
  mkdir -p "${CHILD_TMPDIR}/expected-leftover"
  cleanup_owned_child_tmpdir
  [[ ! -e "${scratch}/child-tmp" ]] || self_test_fail "expected failure cleanup retained its child root"

  set +e
  bash "${BASH_SOURCE[0]}" --rounds 0 >"${scratch}/invalid.out" 2>"${scratch}/invalid.err"
  rc=$?
  set -e
  [[ "${rc}" == "2" ]] || self_test_fail "invalid rounds status was ${rc}"
  grep -qx 'parallel harness: invalid arguments' "${scratch}/invalid.err" \
    || self_test_fail "invalid rounds diagnostic changed"

  set +e
  bash "${BASH_SOURCE[0]}" --rounds 18446744073709551616 >"${scratch}/huge-rounds.out" 2>"${scratch}/huge-rounds.err"
  rc=$?
  set -e
  [[ "${rc}" == "2" ]] || self_test_fail "huge rounds status was ${rc}"
  grep -qx 'parallel harness: invalid arguments' "${scratch}/huge-rounds.err" \
    || self_test_fail "huge rounds diagnostic changed"
  echo "parallel harness self-test: invalid arguments and overflow guard ok"

  interrupt_pid_file="${scratch}/interrupt-grandchild.pid"
  interrupt_root_file="${scratch}/interrupt-root"
  set +e
  INTERRUPT_PID_FILE="${interrupt_pid_file}" INTERRUPT_ROOT_FILE="${interrupt_root_file}" INTERRUPT_SCRATCH="${scratch}" bash -c '
    set -euo pipefail
    source "$1"
    TMPDIR="$INTERRUPT_SCRATCH"
    harness_init parallel-interrupt
    printf "%s\\n" "$TMP" >"$INTERRUPT_ROOT_FILE"
    EVIDENCE_RUN="$TMP/evidence"
    CHILD_TMPDIR="$TMP/child-tmp"
    mkdir -p "$EVIDENCE_RUN" "$CHILD_TMPDIR"
    install_parallel_cleanup_traps
    start_child self interrupt bash -c '\''sleep 30 & child=$!; printf "%s\\n" "$child" >"$1"; wait "$child"'\'' bash "$INTERRUPT_PID_FILE"
    for _ in {1..50}; do
      [[ -s "$INTERRUPT_PID_FILE" ]] && break
      sleep 0.1
    done
    [[ -s "$INTERRUPT_PID_FILE" ]]
    kill -INT "$BASHPID"
  ' bash "${BASH_SOURCE[0]}"
  rc=$?
  set -e
  [[ "${rc}" == "130" ]] || self_test_fail "interruption status was ${rc}"
  [[ -s "${interrupt_pid_file}" ]] || self_test_fail "interruption did not start a grandchild"
  [[ -s "${interrupt_root_file}" ]] || self_test_fail "interruption did not create an owned root"
  grandchild_pid="$(cat "${interrupt_pid_file}")"
  interrupt_root="$(cat "${interrupt_root_file}")"
  ! kill -0 "${grandchild_pid}" 2>/dev/null || self_test_fail "interruption retained a grandchild"
  [[ ! -e "${interrupt_root}" ]] || self_test_fail "interruption retained its owned root"
  echo "parallel harness self-test: signal cleanup and grandchild reaping ok"

  rm -rf -- "${scratch}"
  echo "parallel harness self-test ok"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  parse_arguments "$@"
  if (( SELF_TEST == 1 )); then
    run_self_test
    exit 0
  fi

  harness_init parallel
  install_parallel_cleanup_traps

  if [[ -z "${EVIDENCE_DIR}" ]]; then
    EVIDENCE_DIR="${TMP}/evidence"
  fi
  mkdir -p "${EVIDENCE_DIR}"
  EVIDENCE_RUN="$(mktemp -d "${EVIDENCE_DIR}/parallel.XXXXXX")"
  printf 'unit_snapshot\n' >"${EVIDENCE_RUN}/driver-started"

  PARENT_STATE_ROOT="${TMP}/parent-state"
  for directory in home config data cache state; do
    mkdir -p "${PARENT_STATE_ROOT}/${directory}"
    printf 'parallel parent sentinel %s\n' "${directory}" >"${PARENT_STATE_ROOT}/${directory}/sentinel"
  done
  PARENT_STATE_BEFORE="${EVIDENCE_RUN}/parent-state-before.sha256"
  tree_fingerprint "${PARENT_STATE_ROOT}" >"${PARENT_STATE_BEFORE}"
  CHILD_TMPDIR="${TMP}/child-tmp"
  mkdir -p "${CHILD_TMPDIR}" "${TMP}/units"

  harness_build_snapshot test
  chmod a-w "${UNIT_BIN}"
  sha256sum "${UNIT_BIN}" >"${EVIDENCE_RUN}/unit-snapshot.sha256"

  overall=0
  for (( round = 1; round <= ROUNDS; round++ )); do
    for unit_number in 1 2 3 4; do
      start_unit_child "${round}" "${unit_number}"
    done
    start_script_child "${round}" smoke-1 smoke.sh
    start_script_child "${round}" smoke-2 smoke.sh
    start_script_child "${round}" bench bench.sh

    if ! record_child_statuses; then
      overall=1
    fi
    if ! verify_unit_cleanup; then
      overall=1
    fi
  done

  for (( round = 1; round <= ROUNDS; round++ )); do
    if ! verify_benchmark_json "${EVIDENCE_RUN}/round-${round}-bench.out"; then
      echo "parallel harness: benchmark JSON failed validation for round ${round}" >&2
      overall=1
    fi
  done
  if ! verify_parent_state; then
    echo "parallel harness: parent sentinel state changed" >&2
    overall=1
  fi
  if ! verify_child_tmp_cleanup; then
    echo "parallel harness: child TMPDIR retained files" >&2
    overall=1
  fi

  if (( overall != 0 )); then
    echo "parallel harness failed; evidence: ${EVIDENCE_RUN}" >&2
    exit 1
  fi

  echo "parallel harness ok: rounds=${ROUNDS} evidence=${EVIDENCE_RUN}"
fi
