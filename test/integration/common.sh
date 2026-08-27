#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_LOCK_OWNED=0
HARNESS_TMP_OWNED=0
HARNESS_BUILD_PID=""
HARNESS_BUILD_PROCESS_GROUP=0

harness_cleanup() {
  local status=$?
  trap - EXIT INT TERM
  harness_stop_build
  harness_release_lock || true
  if [[ "${HARNESS_TMP_OWNED}" == "1" && -n "${TMP:-}" ]]; then
    rm -rf -- "${TMP}"
    HARNESS_TMP_OWNED=0
  fi
  return "${status}"
}

harness_stop_build() {
  if [[ -n "${HARNESS_BUILD_PID}" ]]; then
    if [[ "${HARNESS_BUILD_PROCESS_GROUP}" == "1" ]]; then
      kill -TERM -- "-${HARNESS_BUILD_PID}" 2>/dev/null || true
    else
      kill -TERM "${HARNESS_BUILD_PID}" 2>/dev/null || true
    fi
    wait "${HARNESS_BUILD_PID}" 2>/dev/null || true
    HARNESS_BUILD_PID=""
    HARNESS_BUILD_PROCESS_GROUP=0
  fi
}

harness_install_cleanup_trap() {
  trap harness_cleanup EXIT
  trap 'harness_cleanup; exit 130' INT
  trap 'harness_cleanup; exit 143' TERM
}

harness_init() {
  local suite="$1"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/kotoba-${suite}.XXXXXX")"
  HARNESS_TMP_OWNED=1
  harness_install_cleanup_trap
  BIN="${TMP}/bin/kotoba"
  UNIT_BIN="${TMP}/bin/kotoba-tests"
  export HOME="${TMP}/home"
  export XDG_CONFIG_HOME="${TMP}/config"
  export XDG_DATA_HOME="${TMP}/data"
  export XDG_CACHE_HOME="${TMP}/cache"
  export XDG_STATE_HOME="${TMP}/state"
  mkdir -p "${HOME}" "${XDG_CONFIG_HOME}" "${XDG_DATA_HOME}" "${XDG_CACHE_HOME}" "${XDG_STATE_HOME}"
  HARNESS_LOCK_DIR="${ROOT}/.zig-cache/kotoba-integration-build.lock"
}

harness_acquire_lock() {
  local timeout_sec="${1:-600}"
  local started_at="${SECONDS}"
  mkdir -p "$(dirname "${HARNESS_LOCK_DIR}")" || return 1
  while ! mkdir "${HARNESS_LOCK_DIR}" 2>/dev/null; do
    if (( SECONDS - started_at >= timeout_sec )); then
      echo "test harness: build lock timed out" >&2
      return 1
    fi
    sleep 1
  done
  HARNESS_LOCK_OWNED=1
}

harness_release_lock() {
  if [[ "${HARNESS_LOCK_OWNED}" == "1" ]]; then
    rmdir "${HARNESS_LOCK_DIR}"
    HARNESS_LOCK_OWNED=0
  fi
}

harness_invoke_build() {
  local profile="$1"
  local prefix="$2"
  if [[ -n "${HARNESS_BUILD_CALLBACK:-}" ]]; then
    exec "${HARNESS_BUILD_CALLBACK}" "${profile}" "${prefix}"
  fi

  local -a build_args=(test-artifacts --prefix "${prefix}")
  case "${profile}" in
    test) build_args=(-Dtest-backend=true "${build_args[@]}") ;;
    cpu) build_args=(-Dtest-backend=false "${build_args[@]}") ;;
    cuda) build_args=(-Dtest-backend=false -Dcuda=true "${build_args[@]}") ;;
    *)
      echo "test harness: invalid build profile" >&2
      return 2
      ;;
  esac
  cd "${ROOT}" || return 1
  exec env ZIG_GLOBAL_CACHE_DIR="${ROOT}/.zig-cache/global" zig build "${build_args[@]}" 1>&2
}

harness_build_snapshot() {
  local profile="$1"
  local build_prefix="${TMP}/build"
  local staging="${TMP}/.snapshot-$$"
  rm -f -- "${BIN}" "${UNIT_BIN}"
  rm -rf -- "${build_prefix}"
  mkdir -p "${TMP}/bin"
  harness_acquire_lock || return 1

  local restore_job_control=0
  case "$-" in
    *m*) ;;
    *)
      set -m
      restore_job_control=1
      ;;
  esac
  harness_invoke_build "${profile}" "${build_prefix}" &
  HARNESS_BUILD_PID=$!
  HARNESS_BUILD_PROCESS_GROUP=1
  if [[ "${restore_job_control}" == "1" ]]; then
    set +m
  fi
  if ! wait "${HARNESS_BUILD_PID}"; then
    HARNESS_BUILD_PID=""
    HARNESS_BUILD_PROCESS_GROUP=0
    harness_release_lock || true
    return 1
  fi
  HARNESS_BUILD_PID=""
  HARNESS_BUILD_PROCESS_GROUP=0
  if ! mkdir "${staging}" || ! cp "${build_prefix}/bin/kotoba" "${staging}/kotoba" || ! cp "${build_prefix}/bin/kotoba-tests" "${staging}/kotoba-tests"; then
    rm -rf -- "${staging}"
    harness_release_lock || true
    return 1
  fi
  if ! mv "${staging}/kotoba" "${BIN}" || ! mv "${staging}/kotoba-tests" "${UNIT_BIN}"; then
    rm -f -- "${BIN}" "${UNIT_BIN}"
    rm -rf -- "${staging}"
    harness_release_lock || true
    return 1
  fi
  rmdir "${staging}"
  harness_release_lock
}

harness_self_test_fail() {
  echo "harness self-test failed: $*" >&2
  exit 1
}

harness_self_test() {
  local scratch first second rc
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/kotoba-harness-self-test.XXXXXX")"
  TMPDIR="${scratch}"

  harness_init first
  first="${TMP}"
  [[ -d "${HOME}" && -d "${XDG_CONFIG_HOME}" ]] || harness_self_test_fail "first fixture was not initialized"
  harness_cleanup
  [[ ! -e "${first}" ]] || harness_self_test_fail "successful cleanup retained its fixture"

  harness_init second
  second="${TMP}"
  [[ "${first}" != "${second}" ]] || harness_self_test_fail "fixture roots collided"
  harness_cleanup

  HARNESS_LOCK_DIR="${scratch}/fresh/.zig-cache/build.lock"
  harness_acquire_lock 1
  [[ -d "${HARNESS_LOCK_DIR}" ]] || harness_self_test_fail "fresh checkout lock was not acquired"
  harness_release_lock
  rmdir "${scratch}/fresh/.zig-cache"
  rmdir "${scratch}/fresh"

  set +e
  TMPDIR="${scratch}" bash -c 'source "$1"; harness_init error; false' bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
  rc=$?
  set -e
  [[ "${rc}" == "1" ]] || harness_self_test_fail "deliberate error had status ${rc}"
  if compgen -G "${scratch}/kotoba-error.*" >/dev/null; then
    harness_self_test_fail "error cleanup retained its fixture"
  fi

  set +e
  TMPDIR="${scratch}" bash -c 'source "$1"; mkdir() { return 17; }; harness_init mkdir-failure' bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
  rc=$?
  set -e
  [[ "${rc}" == "17" ]] || harness_self_test_fail "mkdir failure had status ${rc}"
  if compgen -G "${scratch}/kotoba-mkdir-failure.*" >/dev/null; then
    harness_self_test_fail "mkdir failure retained its fixture"
  fi

  HARNESS_LOCK_DIR="${scratch}/external.lock"
  mkdir "${HARNESS_LOCK_DIR}"
  HARNESS_LOCK_OWNED=0
  harness_release_lock
  [[ -d "${HARNESS_LOCK_DIR}" ]] || harness_self_test_fail "unowned lock was removed"
  set +e
  harness_acquire_lock 1 >"${scratch}/timeout.out" 2>"${scratch}/timeout.err"
  rc=$?
  set -e
  [[ "${rc}" != "0" ]] || harness_self_test_fail "occupied lock unexpectedly acquired"
  grep -qx 'test harness: build lock timed out' "${scratch}/timeout.err" || harness_self_test_fail "timeout message changed"
  [[ -d "${HARNESS_LOCK_DIR}" ]] || harness_self_test_fail "timeout removed another owner's lock"
  rmdir "${HARNESS_LOCK_DIR}"

  local callback_ok="${scratch}/callback-ok.sh"
  local callback_build_fail="${scratch}/callback-build-fail.sh"
  local callback_copy_fail="${scratch}/callback-copy-fail.sh"
  local callback_interrupt="${scratch}/callback-interrupt.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'mkdir -p "$2/bin"' 'printf ok >"$2/bin/kotoba"' 'printf ok >"$2/bin/kotoba-tests"' 'chmod +x "$2/bin/kotoba" "$2/bin/kotoba-tests"' >"${callback_ok}"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 17' >"${callback_build_fail}"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'mkdir -p "$2/bin"' 'printf partial >"$2/bin/kotoba"' >"${callback_copy_fail}"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'printf "%s\\n" "$$" >"${HARNESS_INTERRUPT_PID_FILE}"' 'sleep 30 &' 'printf "%s\\n" "$!" >"${HARNESS_INTERRUPT_CHILD_PID_FILE}"' 'wait' >"${callback_interrupt}"
  chmod +x "${callback_ok}" "${callback_build_fail}" "${callback_copy_fail}" "${callback_interrupt}"

  harness_init snapshot
  HARNESS_LOCK_DIR="${scratch}/snapshot.lock"
  HARNESS_BUILD_CALLBACK="${callback_ok}"
  harness_build_snapshot test
  [[ -x "${BIN}" && -x "${UNIT_BIN}" ]] || harness_self_test_fail "successful snapshot was incomplete"
  [[ ! -e "${HARNESS_LOCK_DIR}" ]] || harness_self_test_fail "successful snapshot retained its lock"

  HARNESS_BUILD_CALLBACK="${callback_build_fail}"
  set +e
  harness_build_snapshot test
  rc=$?
  set -e
  [[ "${rc}" != "0" && ! -e "${BIN}" && ! -e "${UNIT_BIN}" ]] || harness_self_test_fail "build failure retained a runnable snapshot"
  [[ ! -e "${HARNESS_LOCK_DIR}" ]] || harness_self_test_fail "build failure retained its lock"

  HARNESS_BUILD_CALLBACK="${callback_copy_fail}"
  set +e
  harness_build_snapshot test
  rc=$?
  set -e
  [[ "${rc}" != "0" && ! -e "${BIN}" && ! -e "${UNIT_BIN}" ]] || harness_self_test_fail "copy failure retained a runnable snapshot"
  [[ ! -e "${HARNESS_LOCK_DIR}" ]] || harness_self_test_fail "copy failure retained its lock"

  local interrupt_lock="${scratch}/interrupt.lock"
  local interrupt_pid_file="${scratch}/interrupt-child.pid"
  local interrupt_grandchild_pid_file="${scratch}/interrupt-grandchild.pid"
  HARNESS_BUILD_CALLBACK="${callback_interrupt}" HARNESS_INTERRUPT_PID_FILE="${interrupt_pid_file}" HARNESS_INTERRUPT_CHILD_PID_FILE="${interrupt_grandchild_pid_file}" TMPDIR="${scratch}" bash -c 'source "$1"; harness_init interrupt; HARNESS_LOCK_DIR="$2"; harness_build_snapshot test' bash "${BASH_SOURCE[0]}" "${interrupt_lock}" >/dev/null 2>&1 &
  local interrupt_parent_pid=$!
  for _ in {1..20}; do
    [[ -s "${interrupt_pid_file}" && -s "${interrupt_grandchild_pid_file}" && -d "${interrupt_lock}" ]] && break
    sleep 0.1
  done
  [[ -s "${interrupt_pid_file}" && -s "${interrupt_grandchild_pid_file}" && -d "${interrupt_lock}" ]] || harness_self_test_fail "interrupt build did not start"
  local interrupt_child_pid
  interrupt_child_pid="$(cat "${interrupt_pid_file}")"
  local interrupt_grandchild_pid
  interrupt_grandchild_pid="$(cat "${interrupt_grandchild_pid_file}")"
  kill -TERM "${interrupt_parent_pid}"
  set +e
  wait "${interrupt_parent_pid}"
  rc=$?
  set -e
  [[ "${rc}" == "143" ]] || harness_self_test_fail "interrupt parent had status ${rc}"
  [[ ! -e "${interrupt_lock}" ]] || harness_self_test_fail "interrupt retained its lock"
  if kill -0 "${interrupt_child_pid}" 2>/dev/null; then
    harness_self_test_fail "interrupt retained its build child"
  fi
  if kill -0 "${interrupt_grandchild_pid}" 2>/dev/null; then
    harness_self_test_fail "interrupt retained its build grandchild"
  fi

  harness_cleanup
  rm -rf -- "${scratch}"
  echo "harness self-test ok"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == "--self-test" && "$#" == "1" ]]; then
    harness_self_test
  else
    echo "usage: $0 --self-test" >&2
    exit 2
  fi
fi
