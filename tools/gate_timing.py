#!/usr/bin/env python3
"""Measure Make gates, retain a receipt, and advise without changing command status."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


TEST_STAGES = {"test", "acceptance", "e2e", "kogen-checks-test"}


def summary(duration_ms, stages, exit_status):
    slowest = max(stages, key=lambda row: row["duration_ms"], default=None)
    test_ms = sum(row["duration_ms"] for row in stages if row["name"] in TEST_STAGES)
    warnings = []
    if test_ms >= 10_000:
        warnings.append(f"test suite took {test_ms} ms (10000 ms advisory budget)")
    if duration_ms >= 60_000:
        warnings.append(f"complete check took {duration_ms} ms (60000 ms advisory budget)")
    return {"duration_ms": duration_ms, "test_duration_ms": test_ms,
            "slowest_stage": slowest, "stages": stages, "warnings": warnings,
            "exit_status": exit_status, "status": "passed" if exit_status == 0 else "failed"}


def show(receipt):
    slowest = receipt["slowest_stage"]
    detail = f"{slowest['name']} {slowest['duration_ms']} ms" if slowest else "unavailable"
    evidence = (f"duration {receipt['duration_ms']} ms; tests {receipt['test_duration_ms']} ms; "
                f"slowest stage: {detail}")
    print(f"Gate timing ({receipt['status']}): {evidence}", flush=True)
    for warning in receipt["warnings"]:
        print(f"Time budget warning: {warning}; {evidence}. Correctness is unchanged.",
              file=sys.stderr, flush=True)


def execute(command, env=None):
    started = time.monotonic_ns()
    result = subprocess.run(command, env=env, check=False, close_fds=False)
    return result.returncode, (time.monotonic_ns() - started) // 1_000_000


def main(args):
    mode = args[0]
    if mode == "report":
        show(json.loads(Path(args[1]).read_text()))
        return 0

    name = args[1]
    command = args[3:]
    if args[2] != "--" or not command:
        raise ValueError("usage: gate_timing.py stage|full <name> -- <command...>")

    if mode == "stage":
        status, duration = execute(command)
        row = {"name": name, "duration_ms": duration, "exit_status": status}
        directory = os.environ.get("KOGEN_CHECK_TIMING_DIR")
        if directory:
            with tempfile.NamedTemporaryFile(mode="w", prefix="stage-", suffix=".json",
                                             dir=directory, delete=False) as file:
                json.dump(row, file)
        # Standalone test gates receive the same advice as full checks.
        if name in TEST_STAGES and duration >= 10_000:
            show(summary(duration, [row], status))
        return status

    if mode != "full":
        raise ValueError(f"unknown mode: {mode}")
    root = Path("_build/kogen-gate-timing")
    root.mkdir(parents=True, exist_ok=True)
    directory = tempfile.mkdtemp(prefix="run-", dir=root)
    env = dict(os.environ, KOGEN_CHECK_TIMING_DIR=str(Path(directory).resolve()))
    status, duration = execute(command, env)
    stages = [json.loads(path.read_text()) for path in Path(directory).glob("stage-*.json")]
    receipt = summary(duration, stages, status)
    path = root / f"last-{name}.json"
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    show(receipt)
    print(f"Timing receipt: {path}", flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
