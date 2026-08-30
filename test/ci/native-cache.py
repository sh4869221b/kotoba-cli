#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# How to run: bash test/ci/native-cache.sh identity|validate|stamp [options]
"""Strict, local-only identity and CMake metadata guard for opt-in CI caches."""
from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path


class Mismatch(RuntimeError):
    def __init__(self, field: str) -> None:
        super().__init__(f"linux ci cache: identity mismatch: {field}")


class Fields(dict[str, str]):
    """A flat string-valued identity; reject ambiguous JSON at the boundary."""

    @classmethod
    def parse(cls, pairs: list[tuple[str, str]]) -> Fields:
        result = cls()
        for key, value in pairs:
            if key in result or not isinstance(value, str):
                raise Mismatch(f"duplicate/non-string field {key}")
            result[key] = value
        return result

    def encoded(self) -> str:
        return json.dumps(self, sort_keys=True, separators=(",", ":")) + "\n"


def read_identity(path: Path) -> Fields:
    data = json.loads(path.read_text(), object_pairs_hook=Fields.parse)
    if not isinstance(data, Fields):
        raise Mismatch("JSON object required")
    return data


def output(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30).stdout.strip()


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def executable(name: str) -> str:
    found = shutil.which(name)
    if not found:
        raise Mismatch(f"missing executable {name}")
    return str(Path(found).resolve())


def expected(root: Path, compiler: str, cache: Path) -> Fields:
    fields = Fields(schema="1", compiler=compiler, arch=platform.machine(),
                    os=Path("/etc/os-release").read_text(), zig=output("zig", "version"),
                    source=str(root / "vendor/llama.cpp"), build=str(cache / "llama.cpp/cpu"),
                    generator="Unix Makefiles", profile="cpu-Release-GGML_NATIVE=ON")
    for path in ("build.zig", "build.zig.zon", "test/ci/native-cache.sh", "test/ci/native-cache.py",
                 ".github/actions/setup-linux/action.yml"):
        fields[f"sha256:{path}"] = digest(root / path)
    vendor = root / "vendor/llama.cpp"
    fields["pin.head"] = output("git", "-C", str(vendor), "rev-parse", "HEAD")
    fields["pin.index"] = output("git", "-C", str(root), "ls-files", "--stage", "--", "vendor/llama.cpp")
    pins = re.findall(r'Pinned upstream submodule: `ggml-org/llama.cpp` commit `([a-f0-9]{40})`\.',
                      (root / "docs/embedded-llama-api.md").read_text())
    constants = re.findall(r'const llama_commit = "([a-f0-9]{40})";', (root / "build.zig").read_text())
    if pins != [fields["pin.head"]] or constants != pins or fields["pin.index"] != f"160000 {pins[0]} 0\tvendor/llama.cpp":
        raise Mismatch("pin contract")
    fields["pin.docs"] = pins[0]
    if output("git", "-C", str(vendor), "rev-parse", "--show-toplevel") != str(vendor) or output("git", "-C", str(vendor), "status", "--porcelain"):
        raise Mismatch("vendor checkout/dirty worktree")
    cpu = set()
    for line in Path("/proc/cpuinfo").read_text().splitlines():
        key, sep, value = line.partition(":")
        if sep and key.strip() in ("vendor_id", "cpu family", "model", "stepping", "flags", "CPU implementer", "CPU architecture", "CPU variant", "CPU part", "CPU revision", "Features"):
            cpu.add(f"{key.strip()}={' '.join(sorted(value.split()))}")
    if not cpu:
        raise Mismatch("CPU identity missing")
    fields["cpu"] = "\n".join(sorted(cpu))
    for language, name in (("C", "gcc" if compiler == "gcc" else "clang"), ("CXX", "g++" if compiler == "gcc" else "clang++")):
        driver = executable(name)
        fields[f"{language}.path"] = driver
        fields[f"{language}.sha256"] = digest(Path(driver))
        fields[f"{language}.version"] = output(driver, "--version")
        fields[f"{language}.target"] = output(driver, "-dumpmachine")
        fields[f"{language}.number"] = output(driver, "-dumpfullversion", "-dumpversion")
        fields[f"{language}.id"] = "GNU" if compiler == "gcc" else "Clang"
    fields["cmake"] = output("cmake", "--version")
    fields["launcher"] = executable("ccache")
    fields["ccache"] = output("ccache", "--version")
    fields["packages"] = output("dpkg-query", "-W", "-f=${Package}\t${Version}\n", "build-essential", "gcc", "g++", "clang", "cmake", "ccache", "libc6", "libc6-dev", "libstdc++6", "libsqlite3-dev") if platform.freedesktop_os_release().get("ID") in ("ubuntu", "debian") else "not-dpkg"
    for key in ("CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "CMAKE_TOOLCHAIN_FILE", "CMAKE_GENERATOR_PLATFORM", "CMAKE_GENERATOR_TOOLSET"):
        if os.environ.get(key):
            raise Mismatch(f"unsupported environment {key}")
    if os.environ.get("CMAKE_GENERATOR", fields["generator"]) != fields["generator"]:
        raise Mismatch("CMAKE_GENERATOR")
    return fields


def equal(actual: Fields, wanted: Fields) -> None:
    for key in sorted(actual.keys() | wanted.keys()):
        if actual.get(key) != wanted.get(key):
            raise Mismatch(key)


def metadata(native: Path, identity: Fields) -> None:
    cache = Fields.parse(re.findall(r"^([^#/:\n][^:\n]*):[^=\n]+=([^\n]*)$", (native / "CMakeCache.txt").read_text(), re.M))
    wanted = Fields(CMAKE_HOME_DIRECTORY=identity["source"], CMAKE_CACHEFILE_DIR=identity["build"],
                    CMAKE_GENERATOR=identity["generator"], CMAKE_BUILD_TYPE="Release", GGML_NATIVE="ON", GGML_CPU="ON",
                    GGML_CUDA="OFF", GGML_STATIC="OFF", GGML_OPENMP="OFF", BUILD_SHARED_LIBS="OFF",
                    LLAMA_BUILD_COMMIT=identity["pin.head"], GGML_BUILD_COMMIT=identity["pin.head"],
                    CMAKE_C_FLAGS="", CMAKE_CXX_FLAGS="", CMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG", CMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG")
    for option in ("COMMON", "TESTS", "TOOLS", "EXAMPLES", "SERVER", "APP"):
        wanted[f"LLAMA_BUILD_{option}"] = "OFF"
    for language in ("C", "CXX"):
        key = f"CMAKE_{language}_COMPILER"
        if key not in cache or str(Path(cache[key]).resolve()) != identity[f"{language}.path"]:
            raise Mismatch(key)
        wanted[f"{key}_LAUNCHER"] = identity["launcher"]
        files = list((native / "CMakeFiles").glob(f"*/CMake{language}Compiler.cmake"))
        if len(files) != 1:
            raise Mismatch(f"{language} compiler metadata count")
        compiler_paths = re.findall(rf'^set\({key} "([^"\n]*)"\)$', files[0].read_text(), re.M)
        if len(compiler_paths) != 1 or str(Path(compiler_paths[0]).resolve()) != identity[f"{language}.path"]:
            raise Mismatch(f"{key} generated path")
        for suffix, value in (("ID", identity[f"{language}.id"]), ("VERSION", identity[f"{language}.number"])):
            values = re.findall(rf'^set\({key}_{suffix} "([^"\n]*)"\)$', files[0].read_text(), re.M)
            if values != [value]:
                raise Mismatch(f"{key}_{suffix}")
    for key, value in wanted.items():
        if cache.get(key) != value:
            raise Mismatch(key)


def main() -> int:
    action, compiler, raw_cache, raw_identity = sys.argv[1:]
    root = Path(__file__).resolve().parents[2]
    cache, path = Path(raw_cache).resolve(), Path(raw_identity).resolve()
    native = cache / "llama.cpp/cpu"
    if path == native or native in path.parents:
        raise Mismatch("expected identity must be outside native tree")
    identity = expected(root, compiler, cache)
    if action == "identity":
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(identity.encoded())
        print(f"native_key={hashlib.sha256(identity.encoded().encode()).hexdigest()}")
        compiler_identity = Fields((key, value) for key, value in identity.items() if key not in ("build", "source") and not key.startswith(("pin.", "sha256:")))
        print(f"compiler_key={hashlib.sha256(compiler_identity.encoded().encode()).hexdigest()}")
        return 0
    equal(read_identity(path), identity)
    manifest = native / ".kotoba-native-identity.json"
    if native.is_symlink() or manifest.is_symlink():
        raise Mismatch("symlink native tree/manifest")
    if not native.exists() or not any(native.iterdir()):
        if action == "stamp":
            raise Mismatch("cannot stamp absent build")
        print("native_cache=miss")
        return 0
    if action == "validate" or manifest.exists():
        equal(read_identity(manifest), identity)
    metadata(native, identity)
    if action == "stamp":
        temporary = native / ".kotoba-native-identity.json.tmp"
        with temporary.open("x") as stream:
            stream.write(identity.encoded())
        temporary.replace(manifest)
    print(f"native_cache={'stamped' if action == 'stamp' else 'hit'}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Mismatch, OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error) if isinstance(error, Mismatch) else f"linux ci cache: identity mismatch: {error}", file=sys.stderr)
        sys.exit(1)
