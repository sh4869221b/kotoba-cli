"""Run independent CLI writers under a real advisory lock."""
import fcntl
import os
from pathlib import Path
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
def start(*args, config_home=CONFIG_HOME):
    env = dict(os.environ, XDG_CONFIG_HOME=str(config_home))
    with subprocess.Popen(
        [os.environ["CASE_BIN"], *args],
        env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
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


def main():
    SHARED.mkdir()
    CONFIG.rename(SETTINGS)
    CONFIG.symlink_to(SETTINGS)
    contents = b"fixture-owned lock entry\n"
    with LOCK.open("xb") as lock:
        lock.write(contents)
        lock.flush()
        fcntl.flock(lock, fcntl.LOCK_EX)
        {"retarget": retarget, "concurrent": concurrent}[sys.argv[1]](lock)
    assert LOCK.read_bytes() == contents
    LOCK.unlink()
    assert not list(SHARED.glob(".kotoba-*.tmp"))


if __name__ == "__main__":
    main()
