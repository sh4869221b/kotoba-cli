#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
# Optional test evidence destination; resolve before harness_init changes HOME.
EVIDENCE="${KOTOBA_SECRET_URL_EVIDENCE_DIR:-}"
if [[ -n "${EVIDENCE}" ]]; then
  mkdir -p "${EVIDENCE}"
  EVIDENCE="$(cd "${EVIDENCE}" && pwd)"
fi
harness_init secret-urls
secret_cleanup() {
  local status=$?
  if [[ -n "${EVIDENCE}" && -d "${TMP}/captures" ]]; then
    cp -R "${TMP}/captures/." "${EVIDENCE}/" || status=1
  fi
  harness_cleanup
  if [[ -e "${TMP}" || -n "${HARNESS_BUILD_PID}" || "${HARNESS_LOCK_OWNED}" != 0 ]]; then
    status=1
  fi
  if [[ -n "${EVIDENCE}" ]]; then
    printf 'exit=%s\nprivate_tmp_removed=%s\nbuild_pid=%s\nlock_owned=%s\n' \
      "${status}" "$([[ ! -e "${TMP}" ]] && echo true || echo false)" \
      "${HARNESS_BUILD_PID}" "${HARNESS_LOCK_OWNED}" >"${EVIDENCE}/cleanup.txt"
  fi
  if [[ "${status}" == 0 ]]; then
    echo 'secret URL CLI integration: PASS'
  fi
  exit "${status}"
}
trap secret_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
harness_build_snapshot test
python3 - "${TMP}" "${BIN}" "${UNIT_BIN}" "${ROOT}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tomllib
from datetime import datetime, timezone

tmp, binary, unit, root = map(Path, sys.argv[1:])
captures = tmp / "captures"
captures.mkdir()
identity = "https://models.example.invalid/repo/model%2Bname.gguf"
signed = identity + "?X-Signature=KOTOBA_QUERY_SECRET_36&x=a%2Bb&x=2#KOTOBA_FRAGMENT_SECRET_36"
userinfo = "https://KOTOBA_USER_36:KOTOBA_PASSWORD_36@models.example.invalid/model.gguf?token=KOTOBA_QUERY_SECRET_36#KOTOBA_FRAGMENT_SECRET_36"
warning = "Model registry contains unsafe remote URL metadata. Reads do not change it; the next registry write removes unsafe URL fields. Re-pull with a fresh --model-url when needed."
source_error = "kotoba: model_source_required: Model has no reusable download URL. Run kotoba models pull --model-url HTTPS_URL --id ID --checksum SHA256 with a fresh URL.\n"
invalid_error = "kotoba: invalid_arguments: Invalid arguments.\n"
model_bytes = b"synthetic model bytes for secret URL regression\n"
checksum = hashlib.sha256(model_bytes).hexdigest()
groups: list[str] = []
cases: list[str] = []
binding = {"fullSHA": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
           "suiteSHA256": hashlib.sha256((root / "test/integration/secret_urls.sh").read_bytes()).hexdigest(),
           "sourceDiffSHA256": hashlib.sha256(subprocess.check_output(["git", "diff", "--binary", "HEAD"], cwd=root)).hexdigest()}
env = os.environ.copy()
group = ""
state = tmp
registry = tmp


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean(data: bytes, label: str) -> None:
    assert b"KOTOBA_" not in data, f"{label}: credential marker leaked"


def snapshot() -> dict[str, str]:
    return {str(p.relative_to(state)): digest(p) for p in state.rglob("*") if p.is_file()}


def run(name: str, args: list[str], code: int = 0, out: str | None = None, err: str = "") -> bytes:
    case = f"{group}-{name}"
    assert case not in cases
    result = subprocess.run([str(binary), *args], env=env, capture_output=True, timeout=15)
    (captures / f"{case}.stdout").write_bytes(result.stdout)
    (captures / f"{case}.stderr").write_bytes(result.stderr)
    # URL argv is represented by its fixture digest, never printed in receipts.
    command = [str(binary), *[f"<url-sha256:{hashlib.sha256(a.encode()).hexdigest()}>" if "://" in a else a for a in args]]
    receipt = {**binding, "case": case, "surface": "real-cli", "command": command, "exit": result.returncode,
               "expected_exit": code, "timestamp": datetime.now(timezone.utc).isoformat()}
    (captures / f"{case}.json").write_text(json.dumps(receipt, indent=2) + "\n")
    assert result.returncode == code, f"{case}: exit {result.returncode}, expected {code}"
    clean(result.stdout, case + " stdout")
    clean(result.stderr, case + " stderr")
    assert result.stderr == err.encode(), f"{case}: unexpected stderr"
    if out is not None:
        assert result.stdout == out.encode(), f"{case}: unexpected stdout"
    receipt["exit_and_stream_assertions_passed"] = True
    (captures / f"{case}.json").write_text(json.dumps(receipt, indent=2) + "\n")
    cases.append(case)
    return result.stdout


def entry(model_id: str, download: str = "", source: str = "") -> str:
    fields = {"id": model_id, "name": model_id, "profile": "custom", "format": "gguf",
              "path": str(state / "installed.gguf"), "checksum": checksum,
              "download_url": download, "source_url": source, "notes": "preserve metadata"}
    return "[[models]]\n" + "".join(f'{key} = "{value}"\n' for key, value in fields.items()) + "\n"


def begin(number: int, initialized: bool = True) -> None:
    global group, state, registry, env
    group = f"G{number}"
    groups.append(group)
    state = tmp / group
    env = os.environ.copy()
    for key, directory in [("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                           ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")]:
        path = state / directory
        path.mkdir(parents=True)
        env[key] = str(path)
    registry = state / "config/kotoba/models.toml"
    registry.parent.mkdir(exist_ok=True)
    (state / "installed.gguf").write_bytes(model_bytes)
    if initialized:
        run("setup-init", ["init", "--model-id", "safe36", "--model-path", str(state / "installed.gguf"), "--yes"])
    registry.write_text(entry("safe36") + entry("legacy36", userinfo) + entry("signed36", "", identity))


def unchanged(before: dict[str, str], label: str) -> None:
    after = snapshot()
    (captures / f"{group}-{label}-state.json").write_text(json.dumps({"before": before, "after": after}, indent=2) + "\n")
    assert after == before, f"{group}-{label}: read/failure changed files"


def info(model_id: str, download: str, source: str, label: str = "info") -> None:
    before = snapshot()
    raw = run(label, ["models", "info", model_id])
    fields = dict(line.split(": ", 1) for line in raw.decode().splitlines())
    assert fields["id"] == model_id and fields["path"] == str(state / "installed.gguf")
    assert fields["checksum"] == checksum
    assert fields["download_url"] == download and fields["source_url"] == source, f"{group}: unsafe info metadata"
    unchanged(before, label)


def doctor(json_format: bool, missing: bool = False, unsafe: bool = True, label: str = "doctor") -> None:
    before = snapshot()
    raw = run(label, ["doctor", *(["--format", "json"] if json_format else [])], int(missing))
    if json_format:
        document = json.loads(raw)
        assert document["ok"] is not missing
        found = [check for check in document["checks"] if check["code"] == "model_source_credentials"]
        assert found == ([{"name": "model_source_credentials", "status": "warn", "code": "model_source_credentials", "message": warning}] if unsafe else [])
        assert any(check["code"] == "not_initialized" for check in document["checks"]) == missing
        if not missing:
            assert any(check["name"] == "model_checksum" and check["status"] == "ok" for check in document["checks"])
    else:
        assert raw.decode().count("warn: model_source_credentials: " + warning + "\n") == int(unsafe)
        assert (b"error: config: config.toml is missing or invalid\n" in raw) == missing
    unchanged(before, label)


# Given legacy metadata; when read through each public surface; then no rewrite or leak.
begin(1)
info("legacy36", "https://models.example.invalid/model.gguf", "https://models.example.invalid/model.gguf")
begin(2)
before = snapshot()
run("list", ["models", "list"], out="safe36\tsafe36\tcustom\tcurrent\nlegacy36\tlegacy36\tcustom\nsigned36\tsigned36\tcustom\n")
unchanged(before, "list")
begin(3)
doctor(False)
begin(4)
doctor(True)
begin(5, initialized=False)
doctor(False, missing=True, label="missing-human")
doctor(True, missing=True, label="missing-json")

# NUL cannot occur in OS argv; its rejection belongs to the component tests.
invalid = [("userinfo", userinfo), ("empty-userinfo", "https://@127.0.0.1/model.gguf"),
           ("hostless", "https:///model.gguf"), ("http", "http://127.0.0.1/model.gguf"),
           ("length-8193", "https://127.0.0.1/" + "a" * (8193 - len("https://127.0.0.1/")))]
invalid += [(f"control-{c:02x}", "https://127.0.0.1/model.gguf#x" + chr(c)) for c in [*range(1, 32), 127]]
begin(6)
for label, url in invalid:
    before = snapshot()
    run(label, ["models", "pull", "--model-url", url, "--id", "safe36", "--checksum", checksum,
                "--output", str(state / "installed.gguf")], 2, "", invalid_error)
    unchanged(before, label)

begin(7)
for label, url, code in [("source-only", "", 1), ("legacy-query", signed, 1),
                         ("empty-query", identity + "?", 1), *[(label, url, 2) for label, url in invalid if not label.startswith("control-")]]:
    registry.write_text(entry("signed36", url, identity))
    before = snapshot()
    run(label, ["models", "pull", "signed36"], code, "", source_error if code == 1 else invalid_error)
    unchanged(before, label)

begin(8)
for number, prefix in enumerate(["", "file://"]):
    local = state / f"local{number}?#.gguf"
    local.write_bytes(model_bytes)
    model_id = f"local{number}"
    registry.write_text(entry(model_id, prefix + str(local)))
    output = state / f"pulled{number}.gguf"
    run(model_id, ["models", "pull", model_id, "--output", str(output)], out=f"pulled {model_id}\n")
    saved = tomllib.loads(registry.read_text())["models"][0]
    assert saved["download_url"] == prefix + str(local) and saved["source_url"] == ""
    assert saved["path"] == str(output) and saved["checksum"] == checksum
    assert digest(output) == checksum and digest(local) == checksum
    (captures / f"{group}-{model_id}-registry.toml").write_bytes(registry.read_bytes())

begin(9)
registry.write_text(entry("signed36", "", identity))
registry_before = digest(registry)
run("use", ["models", "use", "signed36"], out="using signed36\n")
assert digest(registry) == registry_before
cfg = tomllib.loads((registry.parent / "config.toml").read_text())
assert cfg["model_id"] == "signed36" and cfg["model_path"] == str(state / "installed.gguf")
before = snapshot()
run("verify", ["models", "verify", "signed36"], out="verified signed36\n")
run("verify-selected", ["models", "verify"], out="verified signed36\n")
unchanged(before, "verify")

for number in [10, 11]:
    begin(number)
    registry.write_text(entry("legacy36", userinfo) + entry("query36", signed) + entry("empty36", identity + "?")
                        + entry("fragment36", identity + "#KOTOBA_FRAGMENT_SECRET_36") + entry("public36", identity)
                        + entry("hostile36", "https:///KOTOBA_QUERY_SECRET_36", "https:///KOTOBA_PASSWORD_36")
                        + entry("source36", "", userinfo) + entry("disposable36"))
    originals = tomllib.loads(registry.read_text())["models"]
    before = snapshot()
    if number == 10:
        run("import", ["models", "import", "--id", "imported36", "--path", str(state / "installed.gguf"), "--checksum", checksum], out="imported imported36\n")
    else:
        run("remove", ["models", "remove", "disposable36", "--yes"], out="removed disposable36\n")
    after = snapshot()
    expected_files = set(before) | ({"data/kotoba/models/imported36.gguf"} if number == 10 else set())
    assert set(after) == expected_files, f"{group}: unexpected registry backup or sidecar"
    assert all(after[key] == value for key, value in before.items() if key != "config/kotoba/models.toml")
    (captures / f"{group}-write-state.json").write_text(json.dumps({"before": before, "after": after}, indent=2) + "\n")
    raw = registry.read_bytes()
    clean(raw, f"{group}: serialized registry")
    saved = {model["id"]: model for model in tomllib.loads(raw.decode())["models"]}
    for original in originals:
        model_id = original["id"]
        if number == 11 and model_id == "disposable36":
            assert model_id not in saved
            continue
        assert all(saved[model_id][key] == original[key] for key in ["id", "path", "checksum", "notes"])
        assert saved[model_id]["download_url"] == (identity if model_id in ["fragment36", "public36"] else "")
        expected_source = "https://models.example.invalid/model.gguf" if model_id in ["legacy36", "source36"] else identity
        assert saved[model_id]["source_url"] == ("" if model_id in ["hostile36", "disposable36"] else expected_source)
    assert digest(state / "installed.gguf") == checksum
    if number == 10:
        assert saved["imported36"]["checksum"] == checksum
        assert digest(Path(saved["imported36"]["path"])) == checksum
    (captures / f"{group}-sanitized-registry.toml").write_bytes(raw)

begin(12)
for label, source, expected in [("hostile", userinfo, "https://models.example.invalid/model.gguf"),
                                ("malformed", "https:///KOTOBA_PASSWORD_36", "[redacted]")]:
    registry.write_text(entry("signed36", "", source))
    info("signed36", "", expected, label)
# Apply the documented manual migration to an actual legacy fixture, preserving the model.
registry.write_text(entry("safe36", signed))
original = tomllib.loads(registry.read_text())["models"][0]
registry.write_text(entry("safe36", "", identity))
migrated = tomllib.loads(registry.read_text())["models"][0]
assert all(migrated[key] == original[key] for key in ["id", "path", "checksum", "notes"])
assert digest(state / "installed.gguf") == checksum
clean(registry.read_bytes(), "manual migration")
doctor(True, unsafe=False, label="manual-migration-doctor")
run("manual-migration-verify", ["models", "verify", "safe36"], out="verified safe36\n")
(captures / "G12-manual-registry.toml").write_bytes(registry.read_bytes())
(captures / "G12-manual-migration.json").write_text(json.dumps({"installed_sha256": digest(state / "installed.gguf"), "checksum": checksum, "preserved": ["id", "path", "checksum", "notes"]}, indent=2) + "\n")

begin(13)
run("debug-config", ["config", "set", "log_level", "debug"], out="")
info("legacy36", "https://models.example.invalid/model.gguf", "https://models.example.invalid/model.gguf", "debug-info")
before = snapshot()
run("debug-list", ["models", "list"], out="safe36\tsafe36\tcustom\tcurrent\nlegacy36\tlegacy36\tcustom\nsigned36\tsigned36\tcustom\n")
unchanged(before, "debug-list")
doctor(False, label="debug-doctor-human")
doctor(True, label="debug-doctor-json")
for label, url in invalid:
    before = snapshot()
    run("debug-" + label, ["models", "pull", "--model-url", url, "--id", "safe36", "--checksum", checksum], 2, "", invalid_error)
    unchanged(before, "debug-" + label)
before = snapshot()
run("debug-source-only", ["models", "pull", "signed36"], 1, "", source_error)
unchanged(before, "debug-source-only")
listener = """import socket
with socket.socket() as server:
    server.bind(('127.0.0.1', 0))
    server.listen(1)
    server.settimeout(10)
    print(server.getsockname()[1], flush=True)
    connection, address = server.accept()
    with connection:
        print('accepted=1', flush=True)
"""
port = 0
output = b""
with subprocess.Popen([sys.executable, "-c", listener], stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
    try:
        assert child.stdout is not None
        assert select.select([child.stdout], [], [], 5)[0], "listener readiness timeout"
        port = int(child.stdout.readline())
        before = snapshot()
        run("tls-failure", ["models", "pull", "--model-url", f"https://127.0.0.1:{port}/model.gguf?token=KOTOBA_QUERY_SECRET_36#KOTOBA_FRAGMENT_SECRET_36",
                            "--id", "safe36", "--checksum", checksum, "--output", str(state / "installed.gguf")],
            1, "", "kotoba: model_registry_invalid: Model registry entry is invalid.\n")
        output, error = child.communicate(timeout=5)
        assert child.returncode == 0 and output == b"accepted=1\n" and error == b""
        unchanged(before, "tls-failure")
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate(timeout=5)
        (captures / "G13-listener.json").write_text(json.dumps({"pid": child.pid, "exit": child.returncode, "joined": child.poll() is not None, "port": port, "accepted": int(output == b"accepted=1\n") if child.returncode == 0 else 0}, indent=2) + "\n")

assert groups == [f"G{i}" for i in range(1, 14)]
assert all(any(case.startswith(g + "-") and not case.endswith("setup-init") for case in cases) for g in groups)
assert not list(tmp.rglob("*.tmp-*")), "owned temporary model file remains"
# The copied unit runner proves signed-success bytes at an injected downloader, not real HTTPS.
result = subprocess.run([str(unit)], cwd=root, capture_output=True, timeout=120)
(captures / "component-unit.stdout").write_bytes(result.stdout)
(captures / "component-unit.stderr").write_bytes(result.stderr)
assert result.returncode == 0, "component unit runner failed"
assert b"secret URL pull pipeline keeps request transient...OK" in result.stderr
assert b"secret URL redirects reject credentials before next request...OK" in result.stderr
manifest = {**binding,
            "binarySHA256": digest(binary), "unitBinarySHA256": digest(unit), "groups": groups,
            "real_cli_cases": len(cases), "setup_cases": sum(c.endswith("setup-init") for c in cases),
            "component_tests": result.stderr.count(b"...OK"), "component_exit": result.returncode,
            "component_command": [str(unit)], "group_case_counts": {g: sum(c.startswith(g + "-") for c in cases) for g in groups},
            "signed_success_surface": "component-injected-downloader", "owned_listener_joined": True,
            "no_model_temp_files": True, "timestamp": datetime.now(timezone.utc).isoformat()}
(captures / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"real CLI groups: {len(groups)}/13 ({', '.join(groups)}); process cases: {len(cases)}")
print(f"component seam: {manifest['component_tests']} unit tests; signed success is not real HTTPS")
PY
