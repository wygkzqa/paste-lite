#!/usr/bin/env python3
"""Run one isolated regression executable with diagnostics for a stalled test."""

import os
from pathlib import Path
import signal
import subprocess
import sys


command = sys.argv[1:]
timeout = int(os.environ.get("TEST_TIMEOUT_SECONDS", "180"))
print(f"RUN: {' '.join(command)} (timeout {timeout}s)", flush=True)
process = subprocess.Popen(command, start_new_session=True)
try:
    result = process.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    report = Path(".build/tests/diagnostics") / f"{Path(command[0]).name}.sample.txt"
    report.parent.mkdir(parents=True, exist_ok=True)
    print(f"FAIL: {command[0]} exceeded {timeout}s; sampling PID {process.pid}", flush=True)
    try:
        subprocess.run(["/usr/bin/sample", str(process.pid), "3", "-file", str(report)], timeout=15)
        if report.exists():
            print(report.read_text(), flush=True)
    finally:
        # Only terminate the process group created for this isolated test.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    result = 124
sys.exit(result if result >= 0 else 128 - result)
