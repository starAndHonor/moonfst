#!/usr/bin/env python3
"""Verify the actual publish archive and an independent local consumer; never publish."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TARGETS = ("native", "js", "wasm-gc", "wasm")


def run(command, cwd):
    subprocess.run(command, cwd=cwd, check=True)


def main():
    with tempfile.TemporaryDirectory(prefix="moonfst-package-") as temporary:
        work = Path(temporary)
        run(["moon", "package", "--target-dir", str(work / "build")], ROOT)
        archives = list((work / "build/publish").glob("*.zip"))
        if len(archives) != 1:
            raise ValueError(f"expected one publish archive, found {archives}")
        package = work / "package"
        with zipfile.ZipFile(archives[0]) as archive:
            names = archive.namelist()
            forbidden = ("artifacts/", "_build/", "target/", ".git/", ".github/",
                         "scripts/", "oracle/", "fixtures/", "benchmarks/",
                         "src/benchmarks/", "src/integration/", "src/automaton/integration/")
            for name in names:
                if name.startswith(forbidden) or name.startswith("/") or ".." in Path(name).parts:
                    raise ValueError(f"unexpected publish archive entry: {name}")
            required = {"moon.mod", "src/moon.pkg", "src/fst.mbt", "src/codec/moon.pkg",
                        "src/automaton/moon.pkg", "src/examples/dictionary/main.mbt",
                        "README.md", "LICENSE", "THIRD_PARTY.md"}
            if not required.issubset(names):
                raise ValueError(f"missing archive files: {required - set(names)}")
            for name in names:
                if not name.endswith("/") and archive.read(name) != (ROOT / name).read_bytes():
                    raise ValueError(f"archive differs from checkout: {name}")
            archive.extractall(package)
        for target in TARGETS:
            run(["moon", "test", "--target", target, "--deny-warn"], package)
        run(["moon", "run", "src/examples/dictionary", "--target", "wasm-gc", "--deny-warn"], package)

        # Resolve the extracted archive, not the checkout or a previously published version.
        (work / "moon.work").write_text('members = ["./package", "./consumer"]\n')
        consumer = work / "consumer"
        consumer.mkdir()
        version = re.search(r'^version\s*=\s*"([^"\n]+)"',
                            (package / "moon.mod").read_text(), re.M).group(1)
        (consumer / "moon.mod").write_text('name = "moonfst/package-consumer"\n\n'
                                          f'import {{ "starAndHonor/fst@{version}" }}\n')
        (consumer / "moon.pkg").write_text('import {\n  "starAndHonor/fst" @fst,\n'
                                          '  "starAndHonor/fst/automaton" @automaton,\n} for "test"\n')
        example = re.search(r"```moonbit\n(test \{.*?\n\})\n```", (package / "README.md").read_text(), re.S)
        if example is None:
            raise ValueError("README must contain a complete MoonBit quickstart test")
        (consumer / "quickstart_test.mbt").write_text(example.group(1) + "\n")
        for target in TARGETS:
            run(["moon", "test", ".", "--target", target, "--deny-warn"], consumer)
        report = {"archive_sha256": hashlib.sha256(archives[0].read_bytes()).hexdigest(),
                  "archive_bytes": archives[0].stat().st_size, "files": names,
                  "targets": list(TARGETS), "archive_tests": "passed",
                  "readme_consumer": "passed", "dictionary_example": "passed"}
        destination = ROOT / "oracle/target/validation/package.json"
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(report, indent=2) + "\n")
        print(f"Publish archive and independent consumer passed; evidence: {destination}")


if __name__ == "__main__":
    main()
