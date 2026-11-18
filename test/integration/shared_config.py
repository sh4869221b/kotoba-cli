"""Run independent CLI writers under a real advisory lock."""
import fcntl
import hashlib
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import tomllib
from contextlib import contextmanager

ROOT = Path(os.environ["CASE_ROOT"])
CONFIG_HOME = Path(os.environ["XDG_CONFIG_HOME"])
CONFIG = CONFIG_HOME / "kotoba/config.toml"
REGISTRY = CONFIG_HOME / "kotoba/models.toml"
MODELS = Path(os.environ["XDG_DATA_HOME"]) / "kotoba/models"
SHARED = ROOT / "shared"
SETTINGS = SHARED / "settings.toml"
LOCK = SHARED / ".kotoba-config.lock"


@contextmanager
def start(*args, config_home=CONFIG_HOME, overrides=None, inherited=()):
    env = dict(os.environ, XDG_CONFIG_HOME=str(config_home))
    env.update(overrides or {})
    with subprocess.Popen(
        [os.environ["CASE_BIN"], *args],
        env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        pass_fds=inherited,
    ) as child:
        try:
            yield child
        finally:
            if child.poll() is None:
                child.kill()


def wait_on_lock(child):
    deadline = time.monotonic() + 10
    fd_directory = Path(f"/proc/{child.pid}/fd")
    while time.monotonic() < deadline and child.poll() is None:
        for descriptor in fd_directory.glob("*"):
            try:
                if descriptor.readlink() == LOCK:
                    return
            except FileNotFoundError:
                continue
        time.sleep(0.01)
    raise AssertionError(f"CLI process did not wait on the shared configuration lock: {child.args}")


def result(child, status, stdout, stderr=b""):
    assert child.communicate(timeout=10) == (stdout, stderr), child.args
    assert child.returncode == status, child.args


def retarget(lock):
    other = SHARED / "other.toml"
    other.write_text("threads = 19\n")
    original = SETTINGS.read_bytes()
    registry = REGISTRY.read_bytes()
    with start("models", "import", "--id", "incoming", "--path", str(MODELS / "fixture.gguf"), "--use") as child:
        wait_on_lock(child)
        assert len(list(MODELS.glob(".kotoba-model.tmp-*"))) == 1
        alternate_link = CONFIG.with_suffix(".new")
        alternate_link.symlink_to(other)
        alternate_link.replace(CONFIG)
        fcntl.flock(lock, fcntl.LOCK_UN)
        result(
            child, 1, b"",
            b"kotoba: config_target_changed: The configuration target changed during the operation. Retry the command.\n",
        )
    assert CONFIG.readlink() == other
    assert SETTINGS.read_bytes() == original and other.read_bytes() == b"threads = 19\n"
    assert REGISTRY.read_bytes() == registry and not (MODELS / "incoming.gguf").exists()
    assert not list(MODELS.glob(".kotoba-model.tmp-*"))


def concurrent(lock):
    second = ROOT / "other-config"
    (second / "kotoba").mkdir(parents=True)
    other_config = second / "kotoba/config.toml"
    other_config.symlink_to(SETTINGS)
    with start("config", "set", "threads", "13") as first:
        with start("config", "set", "log_level", "debug", config_home=second) as other:
            wait_on_lock(first)
            wait_on_lock(other)
            fcntl.flock(lock, fcntl.LOCK_UN)
            result(first, 0, b"")
            result(other, 0, b"")
    settings = tomllib.loads(SETTINGS.read_text())
    assert settings["threads"] == 13 and settings["log_level"] == "debug"
    assert CONFIG.readlink() == SETTINGS == other_config.readlink()


@contextmanager
def pause_cli(operation, path, *args):
    library = Path(os.environ["CASE_DIR"]) / "state-syscall-gate.so"
    source = Path(__file__).with_name("state_syscall_gate.c")
    subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-o", library, source, "-ldl"],
                   check=True, timeout=15)
    ready, write_ready = os.pipe()
    read_resume, resume = os.pipe()
    try:
        overrides = {
            "LD_PRELOAD": str(library),
            f"KOTOBA_TEST_GATE_{operation}": str(path),
            "KOTOBA_TEST_GATE_READY": str(write_ready),
            "KOTOBA_TEST_GATE_RESUME": str(read_resume),
        }
        with start(*args, overrides=overrides, inherited=(write_ready, read_resume)) as child:
            assert select.select([ready], [], [], 10)[0], child.args
            assert os.read(ready, 1) == b"R"
            yield child, resume
    finally:
        for fd in (ready, write_ready, read_resume, resume):
            os.close(fd)


def init_retarget():
    other = SHARED / "other.toml"
    other.write_text("threads = 19\n")
    original = SETTINGS.read_bytes()
    registry = REGISTRY.read_bytes()
    model = MODELS / "fixture.gguf"
    with pause_cli("OPEN", model, "init", "--model-id", "fixture", "--yes") as (child, resume):
        redirect = CONFIG.with_suffix(".new")
        redirect.symlink_to(other)
        redirect.replace(CONFIG)
        os.write(resume, b"R")
        result(child, 1, b"",
               b"kotoba: config_target_changed: The configuration target changed during the operation. Retry the command.\n")
    assert CONFIG.readlink() == other
    assert SETTINGS.read_bytes() == original and other.read_bytes() == b"threads = 19\n"
    assert REGISTRY.read_bytes() == registry


def pull_at_model_publish(kill):
    source = ROOT / "replacement.gguf"
    source.write_bytes(b"replacement model\n")
    checksum = hashlib.sha256(source.read_bytes()).hexdigest()
    with REGISTRY.open("a") as registry:
        registry.write(f'\n[[models]]\nid = "incoming"\ndownload_url = "{source.as_uri()}"\nchecksum = "{checksum}"\n')
    selected = SETTINGS.read_bytes()
    registry = REGISTRY.read_bytes()
    output_dir = ROOT / "output"
    output_dir.mkdir()
    output = output_dir / "model.gguf"
    original = b"original model\n"
    output.write_bytes(original)
    with pause_cli("RENAME", output, "models", "pull", "incoming", "--output", str(output), "--use") as (child, resume):
        assert tomllib.loads(SETTINGS.read_text())["model_id"] == "incoming"
        assert tomllib.loads(REGISTRY.read_text())["models"][-1]["path"] == str(output)
        if kill:
            child.kill()
            result(child, -signal.SIGKILL, b"")
        else:
            edit = SHARED / "editor.toml"
            edited = b"threads = 19\n"
            edit.write_bytes(edited)
            edit.replace(SETTINGS)
            mode = output_dir.stat().st_mode & 0o777
            output_dir.chmod(0o555)
            try:
                assert not os.access(output_dir, os.W_OK)
                os.write(resume, b"R")
                result(child, 1, b"",
                       b"kotoba: state_rollback_conflict: State changed during rollback. Inspect the current files and retained .kotoba-*.tmp backups before retrying.\n")
            finally:
                output_dir.chmod(mode)
            assert SETTINGS.read_bytes() == edited and REGISTRY.read_bytes() == registry
    assert CONFIG.readlink() == SETTINGS and output.read_bytes() == original
    assert any(p.read_bytes() == selected for p in SHARED.glob(".kotoba-*.tmp"))
    if kill:
        assert any(p.read_bytes() == registry for p in REGISTRY.parent.glob(".kotoba-*.tmp"))
        assert any(p.read_bytes() == source.read_bytes() for p in output_dir.glob(".kotoba-model.tmp-*/model.gguf"))
        with start("models", "verify", "incoming") as child:
            result(child, 1, b"", b"kotoba: checksum_failed: Model checksum verification failed.\n")


def main():
    SHARED.mkdir()
    CONFIG.rename(SETTINGS)
    CONFIG.symlink_to(SETTINGS)
    scenario = sys.argv[1]
    if scenario == "init-retarget":
        return init_retarget()
    if scenario in ("rollback-editor", "kill-before-model"):
        return pull_at_model_publish(scenario == "kill-before-model")
    contents = b"fixture-owned lock entry\n"
    with LOCK.open("xb") as lock:
        lock.write(contents)
        lock.flush()
        fcntl.flock(lock, fcntl.LOCK_EX)
        {"retarget": retarget, "concurrent": concurrent}[scenario](lock)
    assert LOCK.read_bytes() == contents
    LOCK.unlink()
    assert not list(SHARED.glob(".kotoba-*.tmp"))


if __name__ == "__main__":
    main()
