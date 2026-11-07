"""Shared test tooling. Rust is an independent oracle, never a runtime dependency."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "oracle" / "Cargo.toml"


def ensure_oracle() -> Path:
    binary = ROOT / "oracle" / "target" / "release" / "moonfst-oracle"
    if os.name == "nt":
        binary = binary.with_suffix(".exe")
    subprocess.run(
        ["cargo", "build", "--quiet", "--locked", "--release", "--manifest-path", str(MANIFEST)],
        cwd=ROOT,
        check=True,
    )
    return binary


class Oracle:
    def __init__(self, binary: Path | None = None):
        self.process = subprocess.Popen(
            [str(binary or ensure_oracle())],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=None,
            text=True,
            encoding="utf-8",
        )

    def request(self, request: dict[str, Any], *, expect_ok: bool = True) -> dict[str, Any]:
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f"oracle exited before answering ({self.process.poll()})")
        response = json.loads(line)
        if expect_ok and response.get("ok") is not True:
            raise RuntimeError(f"oracle rejected request: {response}")
        return response

    def __enter__(self) -> "Oracle":
        return self

    def __exit__(self, *exc: object) -> None:
        if self.process.stdin is not None:
            self.process.stdin.close()
        if self.process.stdout is not None:
            self.process.stdout.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        if exc[0] is None and self.process.returncode != 0:
            raise RuntimeError(f"oracle failed ({self.process.returncode})")


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=True) + "\n").encode("utf-8")


def build_request(kind: str, entries: list[list[str]]) -> dict[str, Any]:
    if kind == "set":
        return {"op": "build", "kind": "set", "keys": [key for key, _ in entries]}
    return {"op": "build", "kind": "map", "entries": entries}


def load_cases() -> tuple[dict[str, Any], list[tuple[dict[str, Any], dict[str, Any], bytes]]]:
    manifest = json.loads((ROOT / "fixtures" / "manifest.json").read_text())
    cases = []
    for case in manifest["cases"]:
        expected = json.loads((ROOT / "fixtures" / case["expected_file"]).read_text())
        data = (ROOT / "fixtures" / case["data_file"]).read_bytes()
        cases.append((case, expected, data))
    return manifest, cases
