#!/usr/bin/env python3
"""Check the tool versions needed for the repository's Linux acceptance suite."""
from __future__ import annotations

import json
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    lock = json.loads((ROOT / "toolchain.json").read_text())
    minimum = tuple(map(int, lock["python_minimum"].split(".")))
    if sys.version_info[:2] < minimum:
        raise SystemExit(f"Python {lock['python_minimum']}+ is required")
    versions = {"python": sys.version, "platform": platform.platform()}
    commands = {"moon": ["moon", "version", "--all"], "rust": ["rustc", "--version"],
                "cargo": ["cargo", "--version"], "node": ["node", "--version"],
                "cc": ["cc", "--version"]}
    for name, command in commands.items():
        try:
            versions[name] = subprocess.check_output(command, cwd=ROOT, text=True).strip()
        except (OSError, subprocess.CalledProcessError) as error:
            raise SystemExit(f"Required tool is unavailable: {command[0]} ({error})") from error
    errors = []
    if platform.system() != lock["validation_os"]:
        errors.append("the full RSS acceptance suite requires Linux")
    if f"moonc v{lock['moonbit']['version']} " not in versions["moon"]:
        errors.append("moonc does not match toolchain.json; run scripts/bootstrap.py")
    if f"moon {lock['moonbit']['moon_version']} " not in versions["moon"]:
        errors.append("moon does not match toolchain.json")
    if not versions["rust"].startswith(f"rustc {lock['rust']} "):
        errors.append("rustc does not match rust-toolchain.toml")
    if not versions["cargo"].startswith(f"cargo {lock['rust']} "):
        errors.append("cargo does not match rust-toolchain.toml")
    if not versions["node"].startswith(f"v{lock['node_major']}."):
        errors.append(f"Node.js {lock['node_major']}.x is required")
    print(json.dumps(versions, indent=2))
    if errors:
        raise SystemExit("\n".join(errors))


if __name__ == "__main__":
    main()
