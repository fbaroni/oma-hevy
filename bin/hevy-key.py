#!/usr/bin/env python3
"""Manage the local Hevy API key.

Usage:
  hevy-key.py save     read the API key from stdin, verify it, save it
  hevy-key.py test     verify the saved key
  hevy-key.py clear    forget the saved key and cached data
  hevy-key.py status   report whether a key is configured
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import hevy_api  # noqa: E402


def fail(message: str, code: int = 1) -> int:
    sys.stderr.write(message.strip() + "\n")
    return code


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else "status"

    if command == "save":
        key = sys.stdin.readline().strip()
        if not key:
            return fail("Paste a Hevy API key first.")
        if len(key) < 20:
            return fail("That does not look like a Hevy API key.")
        try:
            user = hevy_api.fetch_user(key)
        except hevy_api.HevyError as error:
            return fail(str(error))

        config = hevy_api.load_config()
        config["api_key"] = key
        config.setdefault("weekly_target", 4)
        hevy_api.save_config(config)
        hevy_api.clear_snapshot()
        print(json.dumps({"ok": True, "user": user}))
        return 0

    if command == "test":
        try:
            user = hevy_api.fetch_user(hevy_api.api_key())
        except hevy_api.HevyError as error:
            return fail(str(error))
        print(json.dumps({"ok": True, "user": user}))
        return 0

    if command == "clear":
        config = hevy_api.load_config()
        config.pop("api_key", None)
        if config:
            hevy_api.save_config(config)
        else:
            try:
                os.unlink(hevy_api.CONFIG_PATH)
            except OSError:
                pass
        hevy_api.clear_snapshot()
        print(json.dumps({"ok": True}))
        return 0

    if command == "status":
        print(
            json.dumps(
                {
                    "configured": bool(hevy_api.api_key()),
                    "weekly_target": hevy_api.weekly_target(),
                }
            )
        )
        return 0

    return fail("Unknown command: %s" % command, 2)


if __name__ == "__main__":
    raise SystemExit(main())
