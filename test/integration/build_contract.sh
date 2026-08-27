#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
CASE=all
EVIDENCE=""
invalid() { echo 'build contract: invalid arguments' >&2; exit 2; }
while (($#)); do
  case "$1" in
    --case) (($# >= 2)) || invalid; CASE="$2"; shift 2 ;;
    --evidence-dir) (($# >= 2)) || invalid; EVIDENCE="$2"; shift 2 ;;
    *) invalid ;;
  esac
done
case "$CASE" in pin|probe|runner|cache|tools|all) ;; *) invalid ;; esac
[[ "$EVIDENCE" == /* ]] || invalid
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd)"
harness_init build-contract
PIN=9c92e96a64fe0f03f5f3e5ab720a151941da1de5
export ZIG_GLOBAL_CACHE_DIR="${ROOT}/.zig-cache/global"
ORIGINAL_PATH="$PATH"
REAL_CMAKE="$(command -v cmake)"
ASSERTIONS=0
ACTIVE_CASE="setup"
STATUS=0
CAPTURE_PID=""

fail() { echo "build contract: $*" >&2; exit 1; }
assert() {
  local description="$1"; shift
  "$@" || fail "$ACTIVE_CASE: $description"
  ASSERTIONS=$((ASSERTIONS + 1))
  printf '%s\tPASS\t%s\n' "$ACTIVE_CASE" "$description" >>"$TMP/assertions.tsv"
}
capture() {
  local name="$1"; shift
  { printf 'cwd=%q\nargv=' "$PWD"; printf '%q ' "$@"; printf '\n'; } >"$TMP/$name.command"
  if [[ "$1" == harness_build_snapshot ]]; then
    if "$@" >"$TMP/$name.stdout" 2>"$TMP/$name.stderr"; then STATUS=0; else STATUS=$?; fi
  else
    local restore_job_control=0
    case "$-" in *m*) ;; *) set -m; restore_job_control=1 ;; esac
    "$@" >"$TMP/$name.stdout" 2>"$TMP/$name.stderr" &
    CAPTURE_PID=$!
    if [[ "$restore_job_control" == 1 ]]; then set +m; fi
    if wait "$CAPTURE_PID"; then STATUS=0; else STATUS=$?; fi
    CAPTURE_PID=""
  fi
  printf '%s\n' "$STATUS" >"$TMP/$name.status"
}
cleanup() {
  local result=$?
  trap - EXIT INT TERM
  set +e
  if [[ -n "$CAPTURE_PID" ]]; then
    kill -TERM -- "-$CAPTURE_PID" 2>/dev/null
    wait "$CAPTURE_PID" 2>/dev/null
  fi
  harness_stop_build
  git -C "$ROOT/vendor/llama.cpp" status --porcelain --untracked-files=all >"$TMP/vendor.after"
  if ! cmp -s "$TMP/vendor.before" "$TMP/vendor.after"; then
    echo 'build contract: original vendor changed' >&2
    result=1
  fi
  vendor_paths >"$TMP/vendor-paths.after"
  if ! cmp -s "$TMP/vendor-paths.before" "$TMP/vendor-paths.after"; then
    echo 'build contract: new or removed original vendor paths' >&2
    result=1
  fi
  git -C "$ROOT" status --short >"$TMP/source.after"
  printf 'exit=%s\nfixture=%s\n' "$result" "$TMP" >"$TMP/cleanup.txt"
  shopt -s nullglob
  local logs=("$TMP"/*.command "$TMP"/*.stdout "$TMP"/*.stderr "$TMP"/*.status)
  if ((${#logs[@]})); then cp "${logs[@]}" "$EVIDENCE/" || result=1; fi
  for artifact in assertions.tsv counts.tsv source.before source.after vendor.before vendor.after identity.txt cleanup.txt hashes.txt metadata.txt vendor-paths.before vendor-paths.after cmake-record; do
    if [[ -f "$TMP/$artifact" ]]; then cp "$TMP/$artifact" "$EVIDENCE/" || result=1; fi
  done
  local owned="$TMP"
  harness_cleanup
  if [[ -e "$owned" ]]; then result=1; else printf 'fixture_removed=yes\n' >>"$EVIDENCE/cleanup.txt"; fi
  exit "$result"
}
vendor_paths() {
  (cd "$ROOT/vendor/llama.cpp" && find . -path './.git' -prune -o -printf '%P\t%y\n' | LC_ALL=C sort)
}
vendor_paths >"$TMP/vendor-paths.before"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git -C "$ROOT/vendor/llama.cpp" status --porcelain --untracked-files=all >"$TMP/vendor.before"
git -C "$ROOT" status --short >"$TMP/source.before"
{ git -C "$ROOT" rev-parse HEAD; git -C "$ROOT" ls-tree HEAD vendor/llama.cpp; git -C "$ROOT/vendor/llama.cpp" rev-parse --show-toplevel HEAD; zig version; command -v zig; } >"$TMP/identity.txt"
sha256sum "$ROOT/build.zig" "$ROOT/src/llama_api_probe.c" "$ROOT/src/cli.zig" "$ROOT/test/integration/build_contract.sh" >"$TMP/hashes.txt"

fixture() {
  FIXTURE="$TMP/repo-$1"
  capture "$1-clone" git clone --quiet --shared --no-hardlinks "$ROOT" "$FIXTURE"
  assert 'local parent clone' test "$STATUS" -eq 0
  capture "$1-vendor-clone" git clone --quiet --shared --no-hardlinks "$ROOT/vendor/llama.cpp" "$FIXTURE/vendor/llama.cpp"
  assert 'local canonical submodule clone' test "$STATUS" -eq 0
  git -C "$FIXTURE/vendor/llama.cpp" checkout --quiet --detach "$PIN"
  cp "$ROOT/build.zig" "$FIXTURE/build.zig"
  cp "$ROOT/src/llama_api_probe.c" "$FIXTURE/src/llama_api_probe.c"
}
recorder() {
  mkdir -p "$TMP/recorder"
  cat >"$TMP/recorder/cmake" <<'WRAPPER'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$CMAKE_RECORD"
printf 'child_exit=73\n' >&2
exit 73
WRAPPER
  chmod +x "$TMP/recorder/cmake"
  export CMAKE_RECORD="$TMP/cmake-record"
}
expect_preflight() {
  local name="$1" message="$2"
  : >"$CMAKE_RECORD"
  capture "$name" env PATH="$TMP/recorder:$ORIGINAL_PATH" zig build --cache-dir "$TMP/pin-cache" --prefix "$TMP/pin-prefix" -j2
  assert "$name rejected" test "$STATUS" -ne 0
  assert "$name diagnostic" grep -Fq "$message" "$TMP/$name.stderr"
  assert "$name before CMake" test ! -s "$CMAKE_RECORD"
}
case_pin() {
  fixture pin
  cd "$FIXTURE"
  recorder
  capture pin-canonical zig build --help --cache-dir "$TMP/pin-cache"
  assert 'canonical initialized pin accepted' test "$STATUS" -eq 0
  assert 'HEAD gitlink equals pin' test "$(git ls-tree HEAD vendor/llama.cpp | cut -f1)" = "160000 commit $PIN"
  mv vendor/llama.cpp vendor/saved-llama
  expect_preflight pin-missing 'llama.cpp submodule is not initialized; run git submodule update --init --recursive'
  mv vendor/saved-llama vendor/llama.cpp
  mv vendor/llama.cpp/.git "$TMP/vendor-git"
  expect_preflight pin-parent-fallback 'llama.cpp submodule is not initialized; run git submodule update --init --recursive'
  mv "$TMP/vendor-git" vendor/llama.cpp/.git
  # Shallow canonical clones may contain only the pin. Create an actual local
  # commit with the same tree, without changing the original object database.
  local other
  other="$(printf 'build-contract alternate local commit\n' | git -C vendor/llama.cpp -c user.name=build-contract -c user.email=build-contract@example.invalid commit-tree "$PIN^{tree}" -p "$PIN")"
  printf 'fixture=%s\nalternate_commit=%s\nparent=%s\n' "$FIXTURE" "$other" "$PIN" >>"$TMP/metadata.txt"
  git -C vendor/llama.cpp cat-file -e "$other^{commit}"
  git -C vendor/llama.cpp checkout --quiet --detach "$other"
  expect_preflight pin-checkout "llama.cpp pin mismatch: expected $PIN"
  git -C vendor/llama.cpp checkout --quiet --detach "$PIN"
  git update-index --cacheinfo "160000,$other,vendor/llama.cpp"
  expect_preflight pin-index "llama.cpp pin mismatch: expected $PIN"
  git update-index --cacheinfo "160000,$PIN,vendor/llama.cpp"
  cp build.zig "$TMP/saved-build"
  sed "s/$PIN/$other/g" "$TMP/saved-build" >build.zig
  expect_preflight pin-constant 'llama.cpp pin mismatch: expected'
  cp "$TMP/saved-build" build.zig
  cp docs/embedded-llama-api.md "$TMP/saved-doc"
  sed "s/$PIN/$other/g" "$TMP/saved-doc" >docs/embedded-llama-api.md
  expect_preflight pin-doc 'llama.cpp metadata mismatch'
  cp "$TMP/saved-doc" docs/embedded-llama-api.md
  mkdir -p "$TMP/pin-cache/llama.cpp/cpu"
  printf 'LLAMA_BUILD_COMMIT:STRING=%s\nGGML_BUILD_COMMIT:STRING=%s\n' "$other" "$PIN" >"$TMP/pin-cache/llama.cpp/cpu/CMakeCache.txt"
  expect_preflight pin-cache 'llama.cpp metadata mismatch'
  rm "$TMP/pin-cache/llama.cpp/cpu/CMakeCache.txt"
  capture pin-restored zig build --help --cache-dir "$TMP/pin-cache"
  assert 'canonical restored' test "$STATUS" -eq 0
}
case_probe() {
  cd "$ROOT"
  local -a flags=(-Werror=incompatible-pointer-types -fsyntax-only -Ivendor/llama.cpp/include -Ivendor/llama.cpp/ggml/include)
  capture probe-canonical cc "${flags[@]}" src/llama_api_probe.c
  assert 'canonical probe compiled' test "$STATUS" -eq 0
  mkdir -p "$TMP/include"
  cp -a vendor/llama.cpp/include/. "$TMP/include/"
  sed 's/LLAMA_API int32_t llama_tokenize(/LLAMA_API void llama_tokenize(/' vendor/llama.cpp/include/llama.h >"$TMP/include/llama.h"
  assert 'exact tokenize declaration mutated' grep -q 'LLAMA_API void llama_tokenize(' "$TMP/include/llama.h"
  capture probe-drift cc -I"$TMP/include" "${flags[@]}" src/llama_api_probe.c
  assert 'tokenize return drift rejected' test "$STATUS" -ne 0
  assert 'signature diagnostic names tokenize' grep -q llama_tokenize "$TMP/probe-drift.stderr"
  assert 'signature diagnostic is pointer incompatibility' grep -Eq 'incompatible.pointer.types|incompatible pointer type' "$TMP/probe-drift.stderr"
  printf '#include "llama.h"\nvoid old_probe(void) { (void) llama_tokenize; }\n' >"$TMP/old-probe.c"
  capture probe-old-symbol cc -I"$TMP/include" "${flags[@]}" "$TMP/old-probe.c"
  assert 'old symbol expression accepts drift' test "$STATUS" -eq 0
  capture probe-coverage python3 - "$ROOT/src/llama.zig" "$ROOT/src/llama_api_probe.c" <<'PYCODE'
import re, sys
used = set(re.findall(r'c\.(llama_\w+)\s*\(', open(sys.argv[1]).read()))
checked = set(re.findall(r'CHECK_API\((llama_\w+),', open(sys.argv[2]).read()))
assert used and used == checked, (used - checked, checked - used)
print(f'{len(used)} API signatures covered')
PYCODE
  assert 'every adapter function has an exact signature check' test "$STATUS" -eq 0
}
unit_count() {
  local name="$1" mode="$2"
  python3 - "$TMP/$name.stderr" "$mode" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
pattern = r'(\d+)/(\d+) tests passed' if sys.argv[2] == 'build' else r'All (\d+) tests passed\.'
m = re.search(pattern, text)
if not m or int(m[1]) == 0 or (sys.argv[2] == 'build' and m[1] != m[2]):
    raise SystemExit('missing positive passing test count')
print(m[1])
PY
}
case_runner() {
  cd "$ROOT"
  local profile count copied
  for profile in false true; do
    capture "runner-$profile-build" zig build test -Dtest-backend="$profile" --summary all -j2
    assert "$profile build test success" test "$STATUS" -eq 0
    count="$(unit_count "runner-$profile-build" build)" || fail "$profile build test count"
    # Use the existing locked install/copy contract before making a second copy.
    capture "runner-$profile-install" harness_build_snapshot "$([[ "$profile" == true ]] && echo test || echo cpu)"
    assert "$profile test artifacts installed" test "$STATUS" -eq 0
    mkdir -p "$TMP/copied-$profile"
    cp "$UNIT_BIN" "$TMP/copied-$profile/kotoba-tests"
    sha256sum "$UNIT_BIN" "$TMP/copied-$profile/kotoba-tests" >>"$TMP/hashes.txt"
    cd "$TMP/copied-$profile"
    capture "runner-$profile-direct" timeout 120 ./kotoba-tests </dev/null
    assert "$profile copied binary exited with stdin closed" test "$STATUS" -eq 0
    copied="$(unit_count "runner-$profile-direct" direct)" || fail "$profile copied test count"
    assert "$profile direct/build counts match ($count)" test "$count" -eq "$copied"
    printf '%s\t%s\t%s\n' "$profile" "$count" "$copied" >>"$TMP/counts.tsv"
    cd "$ROOT"
  done
}
cache_values() {
  local cache="$1"
  assert 'full LLAMA CMake pin' grep -Eq "^LLAMA_BUILD_COMMIT:[^=]+=$PIN$" "$cache/CMakeCache.txt"
  assert 'full GGML CMake pin' grep -Eq "^GGML_BUILD_COMMIT:[^=]+=$PIN$" "$cache/CMakeCache.txt"
  assert 'CPU CMake CUDA disabled' grep -qx 'GGML_CUDA:BOOL=OFF' "$cache/CMakeCache.txt"
  local short
  short="$(git -C vendor/llama.cpp rev-parse --short "$PIN")"
  assert 'effective upstream short GGML_COMMIT without dirty suffix' grep -Fq "GGML_COMMIT=\\\"$short\\\"" "$cache/ggml/src/CMakeFiles/ggml-base.dir/flags.make"
  { cat "$cache/CMakeCache.txt"; cat "$cache/ggml/src/CMakeFiles/ggml-base.dir/flags.make"; } >>"$TMP/metadata.txt"
}
cache_fingerprint() {
  find "$1" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum
}
case_cache() {
  cd "$ROOT"
  capture cache-cpu zig build --cache-dir "$TMP/local-cache" --prefix "$TMP/private-prefix" -j2
  assert 'actual CPU build in selected cache' test "$STATUS" -eq 0
  assert 'private prefix executable' test -x "$TMP/private-prefix/bin/kotoba"
  cache_values "$TMP/local-cache/llama.cpp/cpu"
  sha256sum "$TMP/private-prefix/bin/kotoba" >>"$TMP/hashes.txt"
  local fingerprint
  fingerprint="$(cache_fingerprint "$TMP/local-cache/llama.cpp/cpu")"
  printf 'cpu_before_cuda=%s\n' "$fingerprint" >>"$TMP/metadata.txt"
  recorder
  capture cache-cuda env PATH="$TMP/recorder:$ORIGINAL_PATH" zig build -Dcuda=true --cache-dir "$TMP/local-cache" --prefix "$TMP/cuda-prefix" -j2
  assert 'CUDA recorder fails parent' test "$STATUS" -ne 0
  assert 'CUDA child status captured' grep -q 'child_exit=73' "$TMP/cache-cuda.stderr"
  assert 'CUDA routes to separate selected cache' grep -Fxq "$TMP/local-cache/llama.cpp/cuda" "$CMAKE_RECORD"
  assert 'CUDA explicitly enabled' grep -Fxq -- '-DGGML_CUDA=ON' "$CMAKE_RECORD"
  assert 'CPU cache unchanged by CUDA failure' test "$fingerprint" = "$(cache_fingerprint "$TMP/local-cache/llama.cpp/cpu")"
  assert 'CUDA failure installs no binary' test ! -e "$TMP/cuda-prefix/bin/kotoba"
  capture cache-relative-cuda zig build -Dcuda-lib-dir=relative --cache-dir "$TMP/local-cache"
  assert 'relative CUDA path rejected' test "$STATUS" -ne 0
  assert 'relative CUDA path diagnostic' grep -q 'cuda-lib-dir must be an absolute path' "$TMP/cache-relative-cuda.stderr"
  mkdir -p "$TMP/tamper"
  cat >"$TMP/tamper/cmake" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_CMAKE" "$@"
if [[ "${1:-}" == -S ]]; then
  while (($#)); do
    if [[ "$1" == -B ]]; then
      sed -i 's/^GGML_BUILD_COMMIT:[^=]*=.*/GGML_BUILD_COMMIT:STRING=invalid/' "$2/CMakeCache.txt"
      break
    fi
    shift
  done
fi
WRAPPER
  chmod +x "$TMP/tamper/cmake"
  capture cache-postconfigure env REAL_CMAKE="$REAL_CMAKE" PATH="$TMP/tamper:$ORIGINAL_PATH" zig build --cache-dir "$TMP/local-cache" --prefix "$TMP/tampered-prefix" -j2
  assert 'postconfigure metadata tampering rejected' test "$STATUS" -ne 0
  assert 'postconfigure metadata mismatch diagnostic' grep -q 'llama.cpp metadata mismatch' "$TMP/cache-postconfigure.stderr"
  assert 'postconfigure mismatch installs no candidate' test ! -e "$TMP/tampered-prefix/bin/kotoba"
  sed -i "s/^GGML_BUILD_COMMIT:[^=]*=.*/GGML_BUILD_COMMIT:STRING=$PIN/" "$TMP/local-cache/llama.cpp/cpu/CMakeCache.txt"
  capture cache-restored zig build --cache-dir "$TMP/local-cache" --prefix "$TMP/private-prefix" -j2
  assert 'real CPU build recovers after metadata restoration' test "$STATUS" -eq 0
}
case_tools() {
  cd "$ROOT"
  recorder
  capture tools-cmake env PATH="$TMP/recorder:$ORIGINAL_PATH" zig build --prefix "$TMP/failed-prefix" -j2
  assert 'cmake failure rejects build' test "$STATUS" -ne 0
  assert 'child exit 73 recorded' grep -q 'child_exit=73' "$TMP/tools-cmake.stderr"
  assert 'failed build installs no binary' test ! -e "$TMP/failed-prefix/bin/kotoba"
  capture tools-recovery zig build --prefix "$TMP/recovered-prefix" -j2
  assert 'real CPU build recovers' test "$STATUS" -eq 0
  assert 'recovered binary installed' test -x "$TMP/recovered-prefix/bin/kotoba"
  mkdir -p "$TMP/no-git"
  printf '#!/usr/bin/env bash\necho "git fixture tool failure" >&2\nexit 73\n' >"$TMP/no-git/git"
  chmod +x "$TMP/no-git/git"
  capture tools-git env PATH="$TMP/no-git:$ORIGINAL_PATH" zig build --help
  assert 'git tool failure rejected' test "$STATUS" -ne 0
  assert 'git tool failure named' grep -qi git "$TMP/tools-git.stderr"
  mkdir -p "$TMP/no-cc"
  printf '#!/usr/bin/env bash\necho "cc fixture tool failure" >&2\nexit 73\n' >"$TMP/no-cc/cc"
  chmod +x "$TMP/no-cc/cc"
  capture tools-cc env PATH="$TMP/no-cc:$ORIGINAL_PATH" zig build --prefix "$TMP/cc-failed-prefix" -j2
  assert 'probe compiler failure rejected' test "$STATUS" -ne 0
  assert 'probe compiler failure named' grep -q 'cc fixture tool failure' "$TMP/tools-cc.stderr"
  assert 'compiler failure installs no binary' test ! -e "$TMP/cc-failed-prefix/bin/kotoba"
}
if [[ "$CASE" == all ]]; then CASES=(pin probe runner cache tools); else CASES=("$CASE"); fi
for ACTIVE_CASE in "${CASES[@]}"; do
  BEFORE="$ASSERTIONS"
  "case_$ACTIVE_CASE"
  ((ASSERTIONS > BEFORE)) || fail "$ACTIVE_CASE executed zero assertions"
  printf 'build contract: %s PASS (%s assertions)\n' "$ACTIVE_CASE" "$((ASSERTIONS - BEFORE))"
done
printf 'build contract: PASS (%s assertions)\n' "$ASSERTIONS"
