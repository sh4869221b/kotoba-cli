#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
CASE=all
NATIVE_CACHE_QA=0
EVIDENCE=""
invalid() { echo 'build contract: invalid arguments' >&2; exit 2; }
while (($#)); do
  case "$1" in
    --case) (($# >= 2)) || invalid; CASE="$2"; shift 2 ;;
    --native-cache-qa) [[ "$NATIVE_CACHE_QA" == 0 ]] || invalid; NATIVE_CACHE_QA=1; shift ;;
    --evidence-dir) (($# >= 2)) || invalid; EVIDENCE="$2"; shift 2 ;;
    *) invalid ;;
  esac
done
case "$CASE" in pin|probe|runner|cache|tools|stages|all) ;; *) invalid ;; esac
[[ "$NATIVE_CACHE_QA" == 0 || "$CASE" == cache || "$CASE" == all ]] || invalid
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
  if ! cmp -s "$TMP/source.before" "$TMP/source.after"; then
    echo 'build contract: original source changed' >&2
    result=1
  fi
  printf 'exit=%s\nfixture=%s\n' "$result" "$TMP" >"$TMP/cleanup.txt"
  shopt -s nullglob
  local logs=("$TMP"/*.command "$TMP"/*.stdout "$TMP"/*.stderr "$TMP"/*.status)
  if ((${#logs[@]})); then cp "${logs[@]}" "$EVIDENCE/" || result=1; fi
  for artifact in assertions.tsv counts.tsv source.before source.after vendor.before vendor.after identity.txt cleanup.txt hashes.txt metadata.txt vendor-paths.before vendor-paths.after cmake-record native-cache-cleanup.txt; do
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
  cp "$ROOT/test/ci/native-cache.sh" "$ROOT/test/ci/native-cache.py" "$ROOT/test/ci/integration-evidence.py" "$ROOT/test/ci/integration-aggregate.sh" "$FIXTURE/test/ci/"
  cp "$ROOT/.github/actions/setup-linux/action.yml" "$FIXTURE/.github/actions/setup-linux/action.yml"
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
  local name="$1" mode="$2" profile="$3"
  python3 - "$TMP/$name.stderr" "$mode" "$profile" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
expected_skip = 1 if sys.argv[3] == 'false' else 0
if sys.argv[2] == 'build':
    matches = re.findall(r'^Build Summary: [^\n]*; (\d+)/(\d+) tests passed(?: \((\d+) skipped\))?$', text, re.M)
    assert len(matches) == 1, 'missing positive passing test count'
    passed, total, skipped = (int(value or 0) for value in matches[0])
    failed = 0
    assert passed + skipped == total
else:
    matches = re.findall(r'^(\d+) passed; (\d+) skipped; (\d+) failed\.$', text, re.M)
    all_passed = re.findall(r'^All (\d+) tests passed\.$', text, re.M)
    assert len(matches) + len(all_passed) == 1, 'missing direct test count'
    passed, skipped, failed = map(int, matches[0]) if matches else (int(all_passed[0]), 0, 0)
    skip_names = re.findall(r'^\d+/\d+ (.+)\.\.\.SKIP$', text, re.M)
    expected_names = ['translate.test.translateSegments sqlite lookup and upsert failures retain prior rows and fresh fixtures recover'] if expected_skip else []
    assert skip_names == expected_names, skip_names
assert passed > 0 and skipped == expected_skip and failed == 0, (passed, skipped, failed)
print(f'{passed}\t{skipped}\t{failed}')
PY
}
case_runner() {
  cd "$ROOT"
  local profile count copied
  for profile in false true; do
    capture "runner-$profile-build" zig build test -Dtest-backend="$profile" --summary all -j2
    assert "$profile build test success" test "$STATUS" -eq 0
    count="$(unit_count "runner-$profile-build" build "$profile")" || fail "$profile build test count"
    # Use the existing locked install/copy contract before making a second copy.
    capture "runner-$profile-install" harness_build_snapshot "$([[ "$profile" == true ]] && echo test || echo cpu)"
    assert "$profile test artifacts installed" test "$STATUS" -eq 0
    mkdir -p "$TMP/copied-$profile"
    cp "$UNIT_BIN" "$TMP/copied-$profile/kotoba-tests"
    sha256sum "$UNIT_BIN" "$TMP/copied-$profile/kotoba-tests" >>"$TMP/hashes.txt"
    cd "$TMP/copied-$profile"
    capture "runner-$profile-direct" timeout 120 ./kotoba-tests </dev/null
    assert "$profile copied binary exited with stdin closed" test "$STATUS" -eq 0
    copied="$(unit_count "runner-$profile-direct" direct "$profile")" || fail "$profile copied test count"
    assert "$profile direct/build counts match ($count)" test "$count" = "$copied"
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
guarded_cache_build() {
  local family="$1" cache="$2" prefix="$3" identity="$4"
  bash test/ci/native-cache.sh validate --compiler "$family" --cache-dir "$cache" --identity "$identity" &&
    zig build --cache-dir "$cache" --prefix "$prefix" -j2 &&
    bash test/ci/native-cache.sh stamp --compiler "$family" --cache-dir "$cache" --identity "$identity" &&
    "$prefix/bin/kotoba" version
}
ccache_hits() {
  ccache --print-stats | awk '$1 == "direct_cache_hit" || $1 == "preprocessed_cache_hit" { hits += $2 } END { print hits+0 }'
}
cache_identity_cases() (
  fixture native-cache
  cd "$FIXTURE"
  local compiler_root family cache identity before after native label file old new saved fingerprint
  mkdir -p "$ROOT/.zig-cache"
  compiler_root="$(mktemp -d "$ROOT/.zig-cache/cache-contract.XXXXXX")"
  cleanup_native_cache_qa() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n "$CAPTURE_PID" ]]; then
      kill -TERM -- "-$CAPTURE_PID" 2>/dev/null
      wait "$CAPTURE_PID" 2>/dev/null
    fi
    rm -rf -- "$compiler_root" "$TMP/native-cache-home"
    if [[ -e "$compiler_root" || -e "$TMP/native-cache-home" ]]; then result=1; fi
    printf 'exit=%s\ncompiler_root=%s\ncompiler_root_removed=%s\nprivate_home_removed=%s\n' "$result" "$compiler_root" "$([[ ! -e "$compiler_root" ]] && echo yes || echo no)" "$([[ ! -e "$TMP/native-cache-home" ]] && echo yes || echo no)" >"$TMP/native-cache-cleanup.txt"
    exit "$result"
  }
  trap cleanup_native_cache_qa EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  export HOME="$TMP/native-cache-home"
  mkdir -p "$HOME"
  export CCACHE_CONFIGPATH=/dev/null CCACHE_COMPILERCHECK=content CCACHE_SLOPPINESS="" CCACHE_HASHDIR=true
  CMAKE_C_COMPILER_LAUNCHER="$(command -v ccache)"
  CMAKE_CXX_COMPILER_LAUNCHER="$CMAKE_C_COMPILER_LAUNCHER"
  export CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER
  for family in gcc clang; do
    export CC=gcc CXX=g++ CCACHE_DIR="$compiler_root/$family"
    [[ "$family" == gcc ]] || { export CC=clang CXX=clang++; }
    mkdir -p "$CCACHE_DIR"
    cache="$TMP/native-$family"
    identity="$TMP/identity-$family.json"
    capture "native-$family-identity" bash test/ci/native-cache.sh identity --compiler "$family" --cache-dir "$cache" --output "$identity"
    assert "$family expected identity created" test "$STATUS" -eq 0
    cat "$identity" >>"$TMP/metadata.txt"
    capture "ccache-$family-before" ccache --show-stats
    capture "native-$family-cold" guarded_cache_build "$family" "$cache" "$TMP/native-prefix-$family" "$identity"
    assert "$family cold native build and CLI version" test "$STATUS" -eq 0
    assert "$family cold is miss" grep -qx 'native_cache=miss' "$TMP/native-$family-cold.stdout"
    capture "ccache-$family-cold" ccache --show-stats
    cache_values "$cache/llama.cpp/cpu"
    cat "$cache/llama.cpp/cpu/CMakeFiles/"*/CMakeCXXCompiler.cmake >>"$TMP/metadata.txt"
    capture "native-$family-warm" guarded_cache_build "$family" "$cache" "$TMP/native-warm-prefix-$family" "$identity"
    assert "$family warm native and CLI version" test "$STATUS" -eq 0
    assert "$family warm is hit" grep -qx 'native_cache=hit' "$TMP/native-$family-warm.stdout"
    capture "native-$family-version" "$TMP/native-warm-prefix-$family/bin/kotoba" version
    assert "$family produced version is nonempty" test -s "$TMP/native-$family-version.stdout"
    before="$(ccache_hits)"
    capture "native-$family-fresh-identity" bash test/ci/native-cache.sh identity --compiler "$family" --cache-dir "$cache-fresh" --output "$TMP/fresh-$family.json"
    assert "$family fresh identity created" test "$STATUS" -eq 0
    capture "native-$family-compiler-warm" guarded_cache_build "$family" "$cache-fresh" "$TMP/native-fresh-prefix-$family" "$TMP/fresh-$family.json"
    assert "$family fresh native warm compiler build and CLI version" test "$STATUS" -eq 0
    after="$(ccache_hits)"
    assert "$family real compiler cache hit count increases" test "$after" -gt "$before"
    capture "ccache-$family-after" ccache --show-stats
    printf 'ccache-%s	before=%s	after=%s	directory=%s
' "$family" "$before" "$after" "$CCACHE_DIR" >>"$TMP/counts.tsv"
    printf 'compiler_cache_%s=%s
' "$family" "$CCACHE_DIR" >>"$TMP/metadata.txt"
  done
  assert 'GCC and Clang CLI version agree' cmp -s "$TMP/native-gcc-version.stdout" "$TMP/native-clang-version.stdout"
  export CC=gcc CXX=g++ CCACHE_DIR="$compiler_root/gcc"
  cache="$TMP/native-gcc"
  native="$cache/llama.cpp/cpu"
  identity="$TMP/identity-gcc.json"
  cp src/main.zig "$TMP/native-main.saved"
  printf '
// cache identity source-only fixture
' >>src/main.zig
  capture native-source-only bash test/ci/native-cache.sh identity --compiler gcc --cache-dir "$cache" --output "$TMP/source-only.json"
  assert 'source-only identity generation succeeds' test "$STATUS" -eq 0
  assert 'source-only change reuses native key' cmp -s "$identity" "$TMP/source-only.json"
  capture native-source-build guarded_cache_build gcc "$cache" "$TMP/source-prefix" "$identity"
  assert 'source-only warm native build and CLI version' test "$STATUS" -eq 0
  cp "$TMP/native-main.saved" src/main.zig
  for file in build.zig build.zig.zon; do
    cp "$file" "$TMP/contract.saved"
    printf '
' >>"$file"
    capture "native-key-$file" bash test/ci/native-cache.sh identity --compiler gcc --cache-dir "$cache" --output "$TMP/changed.json"
    assert "$file changed identity generated" test "$STATUS" -eq 0
    assert "$file changes native key" test "$(sha256sum <"$identity")" != "$(sha256sum <"$TMP/changed.json")"
    cp "$TMP/contract.saved" "$file"
  done
  # The same expected manifest must not conceal incompatible actual CMake metadata.
  local compiler_metadata
  compiler_metadata="$(find "$native/CMakeFiles" -name CMakeCXXCompiler.cmake)"
  while IFS='|' read -r label file old new; do
    [[ "$file" != compiler ]] || file="$compiler_metadata"
    [[ "$file" != cache ]] || file="$native/CMakeCache.txt"
    saved="$TMP/native-$label.saved"
    cp "$file" "$saved"
    sed "$old$new" "$saved" >"$file"
    fingerprint="$(cache_fingerprint "$native")"
    capture "native-reject-$label" guarded_cache_build gcc "$cache" "$TMP/rejected-$label-prefix" "$identity"
    assert "$label rejected before build" test "$STATUS" -ne 0
    assert "$label identity mismatch diagnostic" grep -q 'linux ci cache: identity mismatch' "$TMP/native-reject-$label.stderr"
    assert "$label installs no candidate" test ! -e "$TMP/rejected-$label-prefix"
    assert "$label preserves rejected cache bytes" test "$fingerprint" = "$(cache_fingerprint "$native")"
    printf '%s before=%s after=%s\n' "$label" "$fingerprint" "$(cache_fingerprint "$native")" >>"$TMP/metadata.txt"
    cp "$saved" "$file"
  done <<'MUTATIONS'
compiler-path|cache|s@^CMAKE_CXX_COMPILER:[^=]*=.*@CMAKE_CXX_COMPILER:FILEPATH=/usr/bin/clang++@|
compiler-family|compiler|s/COMPILER_ID "GNU"/COMPILER_ID "Clang"/|
compiler-version|compiler|s/COMPILER_VERSION "[^"]*"/COMPILER_VERSION "0.0.0"/|
missing-version|compiler|/COMPILER_VERSION "/d|
duplicate-compiler|cache|/^CMAKE_CXX_COMPILER:/p|
wrong-pin|cache|s/^GGML_BUILD_COMMIT:[^=]*=.*/GGML_BUILD_COMMIT:STRING=wrong/|
launcher|cache|s@^CMAKE_CXX_COMPILER_LAUNCHER:[^=]*=.*@CMAKE_CXX_COMPILER_LAUNCHER:STRING=/bin/false@|
missing-compiler|cache|/^CMAKE_C_COMPILER:/d|
generated-compiler-path|compiler|s@set(CMAKE_CXX_COMPILER "[^"]*")@set(CMAKE_CXX_COMPILER "/bin/false")@|
CPU-flags|cache|s/^GGML_NATIVE:BOOL=ON/GGML_NATIVE:BOOL=OFF/|
source-path|cache|s@^CMAKE_HOME_DIRECTORY:[^=]*=.*@CMAKE_HOME_DIRECTORY:INTERNAL=/unrelated/source@|
MUTATIONS
  local manifest="$native/.kotoba-native-identity.json"
  cp "$manifest" "$TMP/manifest.saved"
  for label in cpu malformed missing duplicate; do
    case "$label" in
      cpu) python3 - "$manifest" <<'PYCPU'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data['cpu'] = 'different ISA'
path.write_text(json.dumps(data))
PYCPU
      ;;
      malformed) printf '{' >"$manifest" ;;
      missing) mv "$manifest" "$TMP/missing-manifest.saved" ;;
      duplicate) printf '{"schema":"1","schema":"1"}' >"$manifest" ;;
    esac
    fingerprint="$(cache_fingerprint "$native")"
    capture "native-reject-$label" guarded_cache_build gcc "$cache" "$TMP/rejected-$label-prefix" "$identity"
    assert "$label manifest rejected" test "$STATUS" -ne 0
    assert "$label identity mismatch diagnostic" grep -q 'linux ci cache: identity mismatch' "$TMP/native-reject-$label.stderr"
    assert "$label preserves rejected bytes" test "$fingerprint" = "$(cache_fingerprint "$native")"
    assert "$label no candidate" test ! -e "$TMP/rejected-$label-prefix"
    printf '%s before=%s after=%s\n' "$label" "$fingerprint" "$(cache_fingerprint "$native")" >>"$TMP/metadata.txt"
    cp "$TMP/manifest.saved" "$manifest"
  done
  # A warm manifest never replaces the original checkout/index/docs guards in Zig.
  cp docs/embedded-llama-api.md "$TMP/native-doc.saved"
  sed "s/$PIN/0000000000000000000000000000000000000000/g" "$TMP/native-doc.saved" >docs/embedded-llama-api.md
  capture native-warm-pin zig build --cache-dir "$cache" --prefix "$TMP/wrong-pin-prefix" -j2
  assert 'warm native still runs original pin metadata guard' test "$STATUS" -ne 0
  assert 'original warm pin guard diagnostic' grep -q 'llama.cpp metadata mismatch' "$TMP/native-warm-pin.stderr"
  cp "$TMP/native-doc.saved" docs/embedded-llama-api.md
  local alternate
  alternate="$(printf 'native cache pin identity fixture\n' | git -C vendor/llama.cpp -c user.name=build-contract -c user.email=build-contract@example.invalid commit-tree "$PIN^{tree}" -p "$PIN")"
  cp build.zig "$TMP/native-build.saved"
  git -C vendor/llama.cpp checkout --quiet --detach "$alternate"
  git update-index --cacheinfo "160000,$alternate,vendor/llama.cpp"
  sed "s/$PIN/$alternate/g" "$TMP/native-build.saved" >build.zig
  sed "s/$PIN/$alternate/g" "$TMP/native-doc.saved" >docs/embedded-llama-api.md
  capture native-new-pin-identity bash test/ci/native-cache.sh identity --compiler gcc --cache-dir "$cache" --output "$TMP/new-pin.json"
  assert 'consistent changed pin identity generated' test "$STATUS" -eq 0
  assert 'pin contract changes native key' test "$(sha256sum <"$identity")" != "$(sha256sum <"$TMP/new-pin.json")"
  capture native-new-pin-reject bash test/ci/native-cache.sh validate --compiler gcc --cache-dir "$cache" --identity "$TMP/new-pin.json"
  assert 'changed pin rejects old native cache' test "$STATUS" -ne 0
  git -C vendor/llama.cpp checkout --quiet --detach "$PIN"
  git update-index --cacheinfo "160000,$PIN,vendor/llama.cpp"
  cp "$TMP/native-build.saved" build.zig
  cp "$TMP/native-doc.saved" docs/embedded-llama-api.md
  capture native-explicit-recovery guarded_cache_build gcc "$TMP/native-gcc-fresh" "$TMP/recovery-prefix" "$TMP/fresh-gcc.json"
  assert 'explicit independent fresh cache recovery' test "$STATUS" -eq 0
  rm -rf -- "$HOME"
  assert 'private cache QA HOME removed' test ! -e "$HOME"
  assert 'GCC compiler cache outside fixture HOME' test -d "$compiler_root/gcc"
  assert 'Clang compiler cache outside fixture HOME' test -d "$compiler_root/clang"
)
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
  if [[ "${KOTOBA_CI_NATIVE_CACHE:-0}" == 1 ]]; then
    capture cache-identity-self-test bash "$ROOT/test/ci/native-cache.sh" --self-test
    assert 'CI native cache identity self-test passes' test "$STATUS" -eq 0
  fi
  if [[ "$NATIVE_CACHE_QA" == 1 ]]; then
    cache_identity_cases
    ASSERTIONS="$(wc -l <"$TMP/assertions.tsv")"
  fi
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
case_stages() {
  local stage name diagnostic
  for stage in format unit build integration; do
    fixture "stage-$stage"
    mkdir -p "$FIXTURE/test/ci"
    cp "$ROOT/test/ci/linux.sh" "$FIXTURE/test/ci/linux.sh"
    cp "$ROOT/test/ci/integration-evidence.py" "$FIXTURE/test/ci/integration-evidence.py"
    cp "$ROOT/test/integration/build_contract.sh" "$FIXTURE/test/integration/build_contract.sh"
    cd "$FIXTURE"
    cp build.zig "$TMP/stage-$stage-build.saved"
    cp src/main.zig "$TMP/stage-$stage-main.saved"
    sha256sum build.zig src/main.zig >>"$TMP/hashes.txt"
    git status --short >"$TMP/stage-$stage-before"
    name="stage-$stage-baseline"
    capture "$name" env KOTOBA_CI_EVIDENCE_DIR="$EVIDENCE/$name" bash test/ci/linux.sh "$stage"
    assert "$stage real baseline passes" test "$STATUS" -eq 0
    case "$stage" in
      format) printf '\nconst ci_format_probe=1;\n' >>build.zig; diagnostic='build.zig' ;;
      unit) printf '\ntest "ci forced failure" { return error.CiFailure; }\n' >>src/main.zig; diagnostic='ci forced failure' ;;
      build) printf '\nconst ci_invalid = ;\n' >>src/main.zig; diagnostic="expected expression" ;;
      integration) diagnostic='benchmark validation failed: direct translated text mismatch' ;;
    esac
    name="stage-$stage-mutated"
    if [[ "$stage" == integration ]]; then
      capture "$name" env KOTOBA_CI_EVIDENCE_DIR="$EVIDENCE/$name" KOTOBA_BENCH_EXPECT_MISMATCH=1 bash test/ci/linux.sh "$stage"
    else
      capture "$name" env KOTOBA_CI_EVIDENCE_DIR="$EVIDENCE/$name" bash test/ci/linux.sh "$stage"
    fi
    assert "$stage real mutation fails" test "$STATUS" -ne 0
    assert "$stage intended failure observed" grep -Fq "$diagnostic" "$TMP/$name.stdout" "$TMP/$name.stderr"
    cp "$TMP/stage-$stage-build.saved" build.zig
    cp "$TMP/stage-$stage-main.saved" src/main.zig
    assert "$stage build source restored" cmp -s "$TMP/stage-$stage-build.saved" build.zig
    assert "$stage main source restored" cmp -s "$TMP/stage-$stage-main.saved" src/main.zig
    if [[ "$stage" == build ]]; then
      mkdir -p "$TMP/pollution-bin"
      cat >"$TMP/pollution-bin/zig" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$PWD" == "$POLLUTION_ROOT" && "$#" == 1 && "$1" == build ]]; then
  "$REAL_ZIG" "$@"
  printf 'owned build artifact\n' >ci-pollution-owned.txt
else
  exec "$REAL_ZIG" "$@"
fi
WRAPPER
      chmod +x "$TMP/pollution-bin/zig"
      name=stage-build-polluted
      capture "$name" env PATH="$TMP/pollution-bin:$ORIGINAL_PATH" REAL_ZIG="$(command -v zig)" POLLUTION_ROOT="$FIXTURE" KOTOBA_CI_EVIDENCE_DIR="$EVIDENCE/$name" bash test/ci/linux.sh build
      assert 'successful build with source pollution fails stage' test "$STATUS" -ne 0
      assert 'pollution build itself succeeded' grep -qx 0 "$EVIDENCE/$name/production-build.status"
      assert 'pollution source-state diagnostic' grep -Fq 'linux ci: source status changed' "$TMP/$name.stderr"
      assert 'owned build artifact exists' test -f ci-pollution-owned.txt
      rm -- ci-pollution-owned.txt
      printf 'source-pollution\tbuild=0\tstage=nonzero\tartifact_removed=yes\n' >>"$TMP/counts.tsv"
    fi
    name="stage-$stage-restored"
    capture "$name" env KOTOBA_CI_EVIDENCE_DIR="$EVIDENCE/$name" bash test/ci/linux.sh "$stage"
    assert "$stage real restored passes" test "$STATUS" -eq 0
    git status --short >"$TMP/stage-$stage-after"
    assert "$stage fixture source status unchanged" cmp -s "$TMP/stage-$stage-before" "$TMP/stage-$stage-after"
    printf '%s\tbaseline=0\tmutation=nonzero\trestored=0\tsource_restored=yes\n' "$stage" >>"$TMP/counts.tsv"
    cd "$ROOT"
  done
  fixture stage-format-minimal
  mkdir -p "$FIXTURE/test/ci" "$TMP/native-unavailable"
  cp "$ROOT/test/ci/linux.sh" "$FIXTURE/test/ci/linux.sh"
  for tool in cc c++ gcc g++ clang clang++ cmake ccache; do
    printf '#!/usr/bin/env bash\necho native-tool-unavailable >&2\nexit 127\n' >"$TMP/native-unavailable/$tool"
    chmod +x "$TMP/native-unavailable/$tool"
  done
  mv "$FIXTURE/vendor/llama.cpp" "$TMP/stage-format-minimal-vendor"
  cd "$FIXTURE"
  name='stage-format-minimal'
  capture "$name" env PATH="$TMP/native-unavailable:$ORIGINAL_PATH" KOTOBA_CI_EVIDENCE_DIR="$EVIDENCE/$name" bash test/ci/linux.sh format
  assert 'format passes without initialized vendor or native tools' test "$STATUS" -eq 0
  assert 'format records vendor as not required' grep -qx 'vendor=not-required' "$EVIDENCE/$name/identity.txt"
  assert 'format identity omits native tools' sh -c '! grep -Eqi "(cc|cmake).*version" "$1"' sh "$EVIDENCE/$name/identity.txt"
  name='stage-native-minimal'
  capture "$name" env PATH="$TMP/native-unavailable:$ORIGINAL_PATH" KOTOBA_CI_EVIDENCE_DIR="$EVIDENCE/$name" bash test/ci/linux.sh build
  assert 'native stage rejects uninitialized vendor' test "$STATUS" -ne 0
  assert 'native stage names initialization requirement' grep -Fq 'llama.cpp submodule is not initialized' "$TMP/$name.stderr"
  printf 'format-minimal\tformat=0\tnative=nonzero\tvendor=not-required\n' >>"$TMP/counts.tsv"
  cd "$ROOT"

  ACTIVE_CASE=stages
  capture aggregate-self-test bash "$ROOT/test/ci/integration-aggregate.sh" --self-test
  assert 'aggregate self-test covers 64 combinations' test "$STATUS" -eq 0
  assert 'aggregate self-test admits exactly one' grep -Fq '64 combinations, admitted=1, rejected=63' "$TMP/aggregate-self-test.stdout"
  capture aggregate-success bash "$ROOT/test/ci/integration-aggregate.sh" success success success
  assert 'aggregate accepts three successes' test "$STATUS" -eq 0
  for result in failure skipped cancelled missing unknown; do
    capture "aggregate-$result" bash "$ROOT/test/ci/integration-aggregate.sh" success "$result" success
    assert "aggregate rejects $result" test "$STATUS" -ne 0
    assert "aggregate names $result lane failure" grep -Fq 'linux ci: integration lane did not succeed' "$TMP/aggregate-$result.stderr"
  done
  capture aggregate-arity bash "$ROOT/test/ci/integration-aggregate.sh" success success
  assert 'aggregate rejects bad arity with usage status' test "$STATUS" -eq 2

  local workflow="$ROOT/.github/workflows/linux-cpu.yml"
  assert 'workflow keeps format required name' test "$(grep -c '^    name: Linux CPU / format$' "$workflow")" -eq 1
  assert 'workflow keeps build required name' test "$(grep -c '^    name: Linux CPU / build$' "$workflow")" -eq 1
  assert 'workflow keeps unit required name' test "$(grep -c '^    name: Linux CPU / unit$' "$workflow")" -eq 1
  assert 'workflow keeps integration aggregate required name' test "$(grep -c '^    name: Linux CPU / integration$' "$workflow")" -eq 1
  assert 'workflow has smoke lane' grep -Fq '  integration-smoke:' "$workflow"
  assert 'workflow has matrix lane' grep -Fq '  integration-matrix:' "$workflow"
  assert 'workflow has parallel lane' grep -Fq '  integration-parallel:' "$workflow"
  assert 'aggregate needs exactly three lanes' grep -Fqx '    needs: [integration-smoke, integration-matrix, integration-parallel]' "$workflow"
  assert 'aggregate evaluates always' grep -Fqx '    if: ${{ always() }}' "$workflow"
  assert 'parallel maps pull requests to one round and other configured events to two' grep -Fq "github.event_name == 'pull_request' && '1' || '2'" "$workflow"
  assert 'native restores use exact keys only' sh -c '! grep -q "restore-keys:" "$1"' sh "$workflow"
  assert 'cache excludes final and global outputs' sh -c '! grep -E "^[[:space:]]+path: .*(zig-out|\.zig-cache/global|\.lock)" "$1"' sh "$workflow"
  assert 'workflow pins cache restore' grep -Fq 'actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' "$workflow"
  assert 'workflow pins cache save' grep -Fq 'actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' "$workflow"
  assert 'GCC compiler cache save is success miss only' grep -Fq "success() && steps.gcc_compiler_restore.outputs.cache-hit != 'true'" "$workflow"
  assert 'GCC native cache save is success miss only' grep -Fq "success() && steps.gcc_native_restore.outputs.cache-hit != 'true'" "$workflow"
  assert 'Clang compiler cache save is success miss only' grep -Fq "success() && steps.clang_compiler_restore.outputs.cache-hit != 'true'" "$workflow"
  assert 'Clang native cache save is success miss only' grep -Fq "success() && steps.clang_native_restore.outputs.cache-hit != 'true'" "$workflow"
  assert 'workflow pins evidence upload' grep -Fq 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' "$workflow"
  assert 'workflow bounds evidence retention' grep -Fq 'retention-days: 7' "$workflow"
  assert 'format selects minimal setup profile' grep -Fq 'profile: format' "$workflow"
  assert 'aggregate passes needs through environment' grep -Fq 'SMOKE_RESULT: ${{ needs.integration-smoke.result }}' "$workflow"
  assert 'aggregate shell uses environment variables' grep -Fq 'integration-aggregate.sh "$SMOKE_RESULT" "$MATRIX_RESULT" "$PARALLEL_RESULT"' "$workflow"
  printf 'workflow-static\trequired=4\tintegration-children=3\tpr-rounds=1\tpush-rounds=2\tdispatch-rounds=2\n' >>"$TMP/counts.tsv"

  fixture stage-selectors
  mkdir -p "$FIXTURE/test/ci"
  cp "$ROOT/test/ci/linux.sh" "$FIXTURE/test/ci/linux.sh"
  cp "$ROOT/test/ci/integration-evidence.py" "$FIXTURE/test/ci/integration-evidence.py"
  cd "$FIXTURE"
  local invalid_root invalid_name invalid_status
  for invalid_name in rounds-zero rounds-large rounds-nondecimal rounds-missing duplicate-suite unknown-suite matrix-rounds extra-build; do
    invalid_root="$EVIDENCE/stage-selector-invalid-$invalid_name"
    case "$invalid_name" in
      rounds-zero) set -- integration --suite parallel --rounds 0 ;;
      rounds-large) set -- integration --suite parallel --rounds 1001 ;;
      rounds-nondecimal) set -- integration --suite parallel --rounds 01 ;;
      rounds-missing) set -- integration --suite parallel --rounds ;;
      duplicate-suite) set -- integration --suite all --suite all ;;
      unknown-suite) set -- integration --suite unknown ;;
      matrix-rounds) set -- integration --suite matrix --rounds 1 ;;
      extra-build) set -- build --suite parallel ;;
    esac
    capture "stage-selector-invalid-$invalid_name" env KOTOBA_CI_EVIDENCE_DIR="$invalid_root" bash test/ci/linux.sh "$@"
    invalid_status=2
    assert "$invalid_name rejects before fixture allocation" test "$STATUS" -eq "$invalid_status"
    if [[ "$invalid_name" == extra-build ]]; then
      assert "$invalid_name preserves stage diagnostic" grep -qx 'linux ci: invalid stage' "$TMP/stage-selector-invalid-$invalid_name.stderr"
    else
      assert "$invalid_name preserves integration diagnostic" grep -qx 'linux ci: invalid integration arguments' "$TMP/stage-selector-invalid-$invalid_name.stderr"
    fi
    assert "$invalid_name creates no evidence root" test ! -e "$invalid_root"
  done
  local suite rounds name
  while IFS='|' read -r suite rounds; do
    name="stage-selector-$suite-$rounds"
    if [[ "$suite" == parallel ]]; then
      capture "$name" env KOTOBA_CI_EVIDENCE_DIR="$EVIDENCE/$name" bash test/ci/linux.sh integration --suite "$suite" --rounds "$rounds" </dev/null
    else
      capture "$name" env KOTOBA_CI_EVIDENCE_DIR="$EVIDENCE/$name" bash test/ci/linux.sh integration --suite "$suite" </dev/null
    fi
    assert "$suite selected run passes" test "$STATUS" -eq 0
    assert "$suite status names selector" grep -qx "suite=$suite" "$EVIDENCE/$name/status.txt"
    assert "$suite status names rounds" grep -qx "rounds=$rounds" "$EVIDENCE/$name/status.txt"
    assert "$suite common self-test runs" test -s "$EVIDENCE/$name/common.command"
    if [[ "$suite" == smoke ]]; then
      assert 'smoke selected without matrix' test ! -e "$EVIDENCE/$name/cli-matrix.command"
      assert 'smoke selected without parallel' test ! -e "$EVIDENCE/$name/parallel.command"
    elif [[ "$suite" == matrix ]]; then
      assert 'matrix selected without smoke' test ! -e "$EVIDENCE/$name/smoke.command"
      assert 'matrix selected without parallel' test ! -e "$EVIDENCE/$name/parallel.command"
    else
      assert 'parallel selected without smoke' test ! -e "$EVIDENCE/$name/smoke.command"
      assert 'parallel selected without matrix' test ! -e "$EVIDENCE/$name/cli-matrix.command"
      assert "parallel $rounds exact child count" test "$(find "$EVIDENCE/$name/parallel" -mindepth 2 -maxdepth 2 -name 'round-*.status' | wc -l)" -eq "$((9 * rounds))"
      assert "parallel $rounds exact unit log count" test "$(find "$EVIDENCE/$name/parallel" -mindepth 2 -maxdepth 2 -name 'round-*-unit-*.err' | wc -l)" -eq "$((4 * rounds))"
      assert "parallel $rounds exact benchmark count" test "$(find "$EVIDENCE/$name/parallel" -mindepth 2 -maxdepth 2 -name 'round-*-bench.out' | wc -l)" -eq "$rounds"
      assert "parallel $rounds exact measurement count" grep -Fqx "$(printf 'parallel-benchmark-measurements\t%s' "$((15 * rounds))")" "$EVIDENCE/$name/counts.tsv"
      assert "parallel $rounds preserves positive unit total" awk -F '\t' '$1 == "parallel-unit-tests" { found = 1; if ($2 > 0) passed = 1 } END { exit !(found && passed) }' "$EVIDENCE/$name/counts.tsv"
    fi
  done <<'SELECTORS'
smoke|2
matrix|2
parallel|1
parallel|2
SELECTORS
  name=stage-selector-parallel-failure
  capture "$name" env KOTOBA_BENCH_EXPECT_MISMATCH=1 KOTOBA_CI_EVIDENCE_DIR="$EVIDENCE/$name" bash test/ci/linux.sh integration --suite parallel --rounds 1
  assert 'selected benchmark failure propagates' test "$STATUS" -ne 0
  assert 'selected benchmark diagnostic remains visible' grep -Fq 'benchmark validation failed: direct translated text mismatch' "$TMP/$name.stdout" "$TMP/$name.stderr"
  capture stage-selector-parallel-self-test bash test/integration/parallel.sh --self-test
  assert 'parallel signal cleanup self-test passes' test "$STATUS" -eq 0
  local selector_source selector_parallel corrupt label
  selector_source="$EVIDENCE/stage-selector-parallel-1"
  selector_parallel="$(find "$selector_source/parallel" -mindepth 1 -maxdepth 1 -type d -name 'parallel.*')"
  for label in missing-child extra-child wrong-round failed-child bad-benchmark bad-unit-log; do
    corrupt="$TMP/stage-selector-corrupt-$label"
    cp -a "$selector_source" "$corrupt"
    case "$label" in
      missing-child) rm "$corrupt/parallel/$(basename "$selector_parallel")/round-1-unit-1.status" ;;
      extra-child) cp "$corrupt/parallel/$(basename "$selector_parallel")/round-1-unit-1.status" "$corrupt/parallel/$(basename "$selector_parallel")/round-1-unit-5.status" ;;
      wrong-round) mv "$corrupt/parallel/$(basename "$selector_parallel")/round-1-unit-4.status" "$corrupt/parallel/$(basename "$selector_parallel")/round-2-unit-4.status" ;;
      failed-child) sed -i 's/status=0/status=1/' "$corrupt/parallel/$(basename "$selector_parallel")/round-1-unit-1.status" ;;
      bad-benchmark) printf '{}\n' >"$corrupt/parallel/$(basename "$selector_parallel")/round-1-bench.out" ;;
      bad-unit-log) printf 'unexpected unit output\n' >"$corrupt/parallel/$(basename "$selector_parallel")/round-1-unit-1.err" ;;
    esac
    capture "stage-selector-corrupt-$label" python3 test/ci/integration-evidence.py --suite parallel --rounds 1 --evidence-dir "$corrupt"
    assert "$label receipt corruption is rejected" test "$STATUS" -ne 0
  done
  cd "$ROOT"
}
if [[ "$CASE" == all ]]; then CASES=(pin probe runner cache tools); else CASES=("$CASE"); fi
for ACTIVE_CASE in "${CASES[@]}"; do
  BEFORE="$ASSERTIONS"
  "case_$ACTIVE_CASE"
  ((ASSERTIONS > BEFORE)) || fail "$ACTIVE_CASE executed zero assertions"
  printf 'build contract: %s PASS (%s assertions)\n' "$ACTIVE_CASE" "$((ASSERTIONS - BEFORE))"
done
printf 'build contract: PASS (%s assertions)\n' "$ASSERTIONS"
