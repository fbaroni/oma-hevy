#!/usr/bin/env python3
"""Print the Hevy dashboard snapshot as JSON.

Usage: hevy-sync.py [--force] [--demo]
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import hevy_api  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Hevy dashboard snapshot")
    parser.add_argument("--force", action="store_true", help="ignore the cached snapshot")
    parser.add_argument("--demo", action="store_true", help="print sample data (no API key needed)")
    args = parser.parse_args()

    snapshot = hevy_api.demo_snapshot() if args.demo else hevy_api.sync(force=args.force)
    json.dump(snapshot, sys.stdout, separators=(",", ":"), ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
