#!/usr/bin/env bash
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-cache.sh"
ROOT="$(cd "$(dirname "$SELF")/../.." && pwd)"
self_test() (
  set -euo pipefail
  local scratch native count=0 status
  scratch="$(mktemp -d)"
  trap 'rm -rf -- "$scratch"' EXIT
  export CC=gcc CXX=g++ CCACHE_COMPILERCHECK=content CCACHE_CONFIGPATH=/dev/null
  CMAKE_C_COMPILER_LAUNCHER="$(command -v ccache)"
  CMAKE_CXX_COMPILER_LAUNCHER="$CMAKE_C_COMPILER_LAUNCHER"
  export CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER
  native="$scratch/cache/llama.cpp/cpu"
  check() { "$@" || { echo "cache self-test failed: $*" >&2; exit 1; }; count=$((count + 1)); }
  reject() {
    if "$@" >"$scratch/out" 2>"$scratch/err"; then status=0; else status=$?; fi
    check test "$status" -ne 0
    check grep -q 'linux ci cache: identity mismatch' "$scratch/err"
  }
  # Given an absent tree, When validated, Then it is a miss and is not created.
  bash "$SELF" identity --compiler gcc --cache-dir "$scratch/cache" --output "$scratch/identity.json"
  bash "$SELF" validate --compiler gcc --cache-dir "$scratch/cache" --identity "$scratch/identity.json" >"$scratch/out"
  check grep -qx 'native_cache=miss' "$scratch/out"
  check test ! -e "$native"
  # Given nonempty untrusted bytes, When validated/stamped, Then they remain rejected.
  mkdir -p "$native"
  printf 'untrusted\n' >"$native/CMakeCache.txt"
  reject bash "$SELF" validate --compiler gcc --cache-dir "$scratch/cache" --identity "$scratch/identity.json"
  reject bash "$SELF" stamp --compiler gcc --cache-dir "$scratch/cache" --identity "$scratch/identity.json"
  check grep -qx untrusted "$native/CMakeCache.txt"
  for contents in '{' '{}' '{"schema":"1","schema":"1"}' '[]'; do
    printf '%s\n' "$contents" >"$native/.kotoba-native-identity.json"
    reject bash "$SELF" validate --compiler gcc --cache-dir "$scratch/cache" --identity "$scratch/identity.json"
  done
  # Given an identity from another compiler, When used for GCC, Then it fails.
  bash "$SELF" identity --compiler clang --cache-dir "$scratch/cache" --output "$scratch/clang.json"
  reject bash "$SELF" validate --compiler gcc --cache-dir "$scratch/cache" --identity "$scratch/clang.json"
  for arguments in '' 'identity' 'identity --compiler bad --output /tmp/out' 'identity --compiler gcc --output relative' 'validate --compiler gcc --identity /tmp/a --cache-dir relative'; do
    read -r -a words <<<"$arguments"
    if bash "$SELF" "${words[@]}" >"$scratch/out" 2>"$scratch/err"; then status=0; else status=$?; fi
    check test "$status" -eq 2
    check grep -qx 'linux ci cache: invalid arguments' "$scratch/err"
  done
  printf 'native cache self-test PASS (%s assertions)\n' "$count"
)
if [[ "$#" == 1 && "$1" == --self-test ]]; then self_test; exit; fi
invalid() { echo 'linux ci cache: invalid arguments' >&2; exit 2; }
(($#)) || invalid
ACTION="$1"; shift
case "$ACTION" in identity|validate|stamp) ;; *) invalid ;; esac
COMPILER="" CACHE="" IDENTITY=""
while (($#)); do
  (($# >= 2)) || invalid
  case "$1" in
    --compiler) [[ -z "$COMPILER" ]] || invalid; COMPILER="$2" ;;
    --cache-dir) [[ -z "$CACHE" && "$2" == /* ]] || invalid; CACHE="$2" ;;
    --output) [[ "$ACTION" == identity && -z "$IDENTITY" && "$2" == /* ]] || invalid; IDENTITY="$2" ;;
    --identity) [[ "$ACTION" != identity && -z "$IDENTITY" && "$2" == /* ]] || invalid; IDENTITY="$2" ;;
    *) invalid ;;
  esac
  shift 2
done
case "$COMPILER" in gcc|clang) ;; *) invalid ;; esac
[[ -n "$IDENTITY" ]] || invalid
if [[ -z "$CACHE" ]]; then
  [[ "$ACTION" == identity ]] || invalid
  CACHE="$ROOT/.zig-cache"
  [[ "$COMPILER" == gcc ]] || CACHE="$CACHE/ci-clang"
fi
exec python3 "${SELF%.sh}.py" "$ACTION" "$COMPILER" "$CACHE" "$IDENTITY"
