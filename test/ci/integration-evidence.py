#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# How to run: python3 test/ci/integration-evidence.py --suite all --rounds 2 --evidence-dir /absolute/path
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Final, NoReturn, TypeAlias

GROUPS: Final = frozenset(("translate", "commands", "memory", "files"))
LABELS: Final = ("unit-1", "unit-2", "unit-3", "unit-4", "smoke-1", "smoke-2", "bench", "matrix-1", "matrix-2")
JsonValue: TypeAlias = str | int | float | bool | None | list["JsonValue"] | dict[str, "JsonValue"]


@dataclass(frozen=True, slots=True)
class EvidenceError(Exception):
    message: str

    def __str__(self) -> str:
        return f"linux ci integration evidence: {self.message}"


def fail(message: str) -> NoReturn:
    raise EvidenceError(message)


def parse_arguments(arguments: list[str]) -> tuple[str, int, Path]:
    if len(arguments) != 6 or arguments[0::2] != ["--suite", "--rounds", "--evidence-dir"]:
        fail("invalid arguments")
    suite, raw_rounds, raw_evidence = arguments[1::2]
    if suite not in {"all", "smoke", "matrix", "parallel"}:
        fail("invalid suite")
    if not re.fullmatch(r"[1-9][0-9]{0,3}", raw_rounds):
        fail("invalid rounds")
    rounds = int(raw_rounds)
    if rounds > 1000:
        fail("invalid rounds")
    evidence = Path(raw_evidence)
    if not evidence.is_absolute():
        fail("evidence directory must be absolute")
    return suite, rounds, evidence


def only_one(root: Path, pattern: str, description: str) -> Path:
    paths = sorted(root.glob(pattern))
    if len(paths) != 1:
        fail(f"expected one {description}: {paths}")
    return paths[0]


def read_json(path: Path) -> dict[str, JsonValue]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        fail(f"JSON object required: {path}")
    return data


def check_common(root: Path) -> None:
    if "harness self-test ok" not in (root / "common.stdout").read_text(encoding="utf-8"):
        fail("common self-test receipt missing")


def check_smoke(root: Path) -> None:
    if "smoke ok" not in (root / "smoke.stdout").read_text(encoding="utf-8"):
        fail("smoke receipt missing")


def check_matrix(root: Path) -> Counter[str]:
    matrix = only_one(root / "cli-matrix", "cli-matrix.*", "matrix run")
    summary = read_json(matrix / "summary.json")
    receipts = [read_json(path) for path in sorted((matrix / "cases").glob("*/receipt.json"))]
    groups = Counter(str(receipt.get("group")) for receipt in receipts)
    if set(groups) != GROUPS or not all(groups.values()):
        fail(f"matrix groups: {groups}")
    if summary.get("groups") != dict(groups) or summary.get("passed") != len(receipts) or not receipts:
        fail("matrix summary count mismatch")
    case_ids = {str(receipt.get("case_id")) for receipt in receipts}
    if len(case_ids) != len(receipts) or set(summary.get("cases", [])) != case_ids:
        fail("matrix case IDs mismatch")
    for receipt in receipts:
        if receipt.get("level") != "cli" or receipt.get("verdict") != "pass" or receipt.get("harness_timeout"):
            fail("matrix receipt verdict")
        assertions = receipt.get("assertions")
        if not isinstance(assertions, list) or not assertions or not all(isinstance(item, dict) and item.get("passed") is True for item in assertions):
            fail("matrix receipt assertions")
        case = matrix / "cases" / str(receipt.get("case_id"))
        if int((case / "status").read_text(encoding="utf-8")) != receipt.get("status"):
            fail("matrix receipt status")
        for artifact in ("stdout", "stderr", "fs_before", "fs_after", "db_before", "db_after"):
            if not (case / str(receipt.get(artifact))).is_file():
                fail(f"matrix artifact {artifact}")
    cleanup = read_json(matrix / "cleanup.json")
    if cleanup.get("exit_status") != 0 or cleanup.get("temporary_removed") is not True or cleanup.get("lock_released") is not True:
        fail("matrix cleanup")
    return groups


def expected_parallel_files(rounds: int) -> set[str]:
    return {f"round-{round_id}-{label}.status" for round_id in range(1, rounds + 1) for label in LABELS}


def check_parallel(root: Path, rounds: int) -> tuple[int, int, int]:
    parallel = only_one(root / "parallel", "parallel.*", "parallel run")
    actual = {path.name for path in parallel.glob("round-*.status")}
    expected = expected_parallel_files(rounds)
    if actual != expected:
        fail(f"parallel child labels: missing={sorted(expected - actual)} extra={sorted(actual - expected)}")
    for round_id in range(1, rounds + 1):
        for label in LABELS:
            status = (parallel / f"round-{round_id}-{label}.status").read_text(encoding="utf-8")
            if re.fullmatch(rf"round={round_id} child={re.escape(label)} pid=[1-9][0-9]* status=0\n?", status) is None:
                fail(f"parallel child status: round={round_id} child={label}")
    unit_paths = {path.name for path in parallel.glob("round-*-unit-*.err")}
    expected_units = {f"round-{round_id}-unit-{number}.err" for round_id in range(1, rounds + 1) for number in range(1, 5)}
    if unit_paths != expected_units:
        fail("parallel unit logs")
    unit_tests = 0
    for path in unit_paths:
        matches = re.findall(r"^All (\d+) tests passed\.$", (parallel / path).read_text(encoding="utf-8"), re.MULTILINE)
        if len(matches) != 1 or int(matches[0]) <= 0:
            fail(f"parallel unit log: {path}")
        unit_tests += int(matches[0])
    benchmark_paths = {f"round-{round_id}-bench.out" for round_id in range(1, rounds + 1)}
    if {path.name for path in parallel.glob("round-*-bench.out")} != benchmark_paths:
        fail("parallel benchmark files")
    measurements = 0
    for path in benchmark_paths:
        payload = read_json(parallel / path)
        if payload.get("iterations") != 5 or not isinstance(payload.get("inputs"), list) or len(payload["inputs"]) != 3:
            fail(f"parallel benchmark: {path}")
        measurements += 15
    cleanup = read_json(parallel / "cleanup.json")
    if cleanup.get("exit_status") != 0 or cleanup.get("temporary_removed") is not True or cleanup.get("lock_released") is not True or cleanup.get("remaining_children") != []:
        fail("parallel cleanup")
    verified = read_json(parallel / "matrix-verification.json")
    children = verified.get("children")
    if not isinstance(children, list) or len(children) != 2 * rounds or verified.get("concurrent_rounds") != rounds:
        fail("parallel matrix verification")
    return len(unit_paths), unit_tests, measurements


def main() -> int:
    suite, rounds, root = parse_arguments(sys.argv[1:])
    check_common(root)
    if suite in {"all", "smoke"}:
        check_smoke(root)
    elif (root / "smoke.command").exists():
        fail("nonselected smoke executed")
    counts: Counter[str] = Counter(common=1)
    if suite in {"all", "matrix"}:
        for group, count in check_matrix(root).items():
            counts[f"cli-matrix-{group}"] = count
        counts["cli-matrix-total"] = sum(counts[key] for key in counts if key.startswith("cli-matrix-") and key != "cli-matrix-total")
    elif (root / "cli-matrix.command").exists():
        fail("nonselected matrix executed")
    if suite in {"all", "parallel"}:
        unit_logs, unit_tests, measurements = check_parallel(root, rounds)
        counts["parallel-children"] = 9 * rounds
        counts["parallel-unit-logs"] = unit_logs
        counts["parallel-unit-tests"] = unit_tests
        counts["parallel-benchmarks"] = rounds
        counts["parallel-benchmark-measurements"] = measurements
    elif (root / "parallel.command").exists():
        fail("nonselected parallel executed")
    if suite in {"all", "smoke"}:
        counts["smoke"] = 1
    for key in sorted(counts):
        print(f"{key}\t{counts[key]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
