#!/usr/bin/env python3
"""Run P2FILE's Python unit and emulator-integration tests."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


def main() -> int:
    repository = Path(__file__).resolve().parents[1]
    suite = unittest.defaultTestLoader.discover(
        str(repository / "tests"), top_level_dir=str(repository)
    )
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
