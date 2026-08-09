#!/usr/bin/python3
import os
import sys
import time
from pathlib import Path

root = Path(os.environ["SIMLEASE_FAKE_ROOT"])
args = sys.argv[1:]
try:
    udid = args[args.index("--udid") + 1]
except (ValueError, IndexError):
    sys.exit(96)

mode = os.environ.get("SIMLEASE_FAKE_AXE_MODE", "")
if mode == "pair":
    (root / f"axe-start-{udid}").touch()
    expected = [os.environ["SIMLEASE_EXPECT_A"], os.environ["SIMLEASE_EXPECT_B"]]
    deadline = time.time() + 2
    while time.time() < deadline:
        if all((root / f"axe-start-{value}").exists() for value in expected):
            sys.exit(0)
        time.sleep(0.01)
    sys.exit(9)
elif mode == "same":
    critical = root / "axe-critical"
    try:
        critical.mkdir()
    except FileExistsError:
        (root / "axe-overlap").touch()
        sys.exit(9)
    time.sleep(0.15)
    critical.rmdir()
