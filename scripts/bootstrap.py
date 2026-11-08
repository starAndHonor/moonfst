#!/usr/bin/env python3
"""Install the pinned MoonBit archives without changing shell profiles or ~/.moon."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            result.update(block)
    return result.hexdigest()


def obtain(artifact, cache):
    destination = cache / (artifact["sha256"] + ".tar.gz")
    if destination.exists():
        if sha256(destination) != artifact["sha256"]:
            raise ValueError(f"cached archive has an incorrect SHA256: {destination}")
        return destination
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=cache, prefix="download-") as temporary:
        downloaded = Path(temporary) / "archive.tar.gz"
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                        "--retry", "3", "--connect-timeout", "20", "--max-time", "300",
                        artifact["url"], "--output", str(downloaded)], check=True)
        if sha256(downloaded) != artifact["sha256"]:
            raise ValueError(f"downloaded archive has an incorrect SHA256: {artifact['url']}")
        downloaded.replace(destination)
    return destination


def extract(archive, destination):
    # Hash verification precedes extraction; reject unexpected absolute/parent paths too.
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            if member.name.startswith("/") or ".." in Path(member.name).parts:
                raise ValueError(f"unsafe archive entry: {member.name}")
        source.extractall(destination, filter="tar")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=ROOT / "artifacts/toolchains/moon")
    parser.add_argument("--cache", type=Path, default=ROOT / "artifacts/cache/toolchains")
    args = parser.parse_args()
    lock = json.loads((ROOT / "toolchain.json").read_text())
    target = f"{platform.system().lower()}-{platform.machine().lower()}"
    if target not in lock["moonbit"]["archives"]:
        parser.error(f"automated bootstrap supports {list(lock['moonbit']['archives'])}, got {target}")
    prefix = args.prefix.resolve()
    identity = lock["moonbit"]
    marker = prefix / ".moonfst-toolchain.json"
    if marker.exists() and json.loads(marker.read_text()) == identity:
        print(f"Pinned MoonBit installation already present: {prefix}")
    else:
        if prefix.exists() and any(prefix.iterdir()):
            parser.error(f"prefix is not empty; select a new --prefix: {prefix}")
        compiler = obtain(identity["archives"][target], args.cache)
        core = obtain(identity["core"], args.cache)
        prefix.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=prefix.parent, prefix="moonfst-install-") as temporary:
            staging = Path(temporary) / "moon"
            staging.mkdir()
            extract(compiler, staging)
            (staging / "lib").mkdir(exist_ok=True)
            extract(core, staging / "lib")
            executable = staging / "bin/moon"
            environment = dict(os.environ, MOON_HOME=str(staging),
                               PATH=str(staging / "bin") + os.pathsep + os.environ.get("PATH", ""))
            subprocess.run([str(executable), "-C", str(staging / "lib/core"), "bundle",
                            "--target", "wasm-gc", "--warn-list", "-a", "--quiet"],
                           check=True, env=environment)
            (staging / ".moonfst-toolchain.json").write_text(json.dumps(identity, indent=2) + "\n")
            if prefix.exists():
                prefix.rmdir()
            shutil.move(str(staging), str(prefix))
    version = subprocess.check_output([str(prefix / "bin/moon"), "version", "--all"], text=True)
    if f"moonc v{identity['version']} " not in version or f"moon {identity['moon_version']} " not in version:
        raise ValueError(f"installed compiler/build tool does not match toolchain.json:\n{version}")
    environment_file = ROOT / "artifacts/env.sh"
    environment_file.parent.mkdir(parents=True, exist_ok=True)
    environment_file.write_text(
        f"export MOON_HOME={shlex.quote(str(prefix))}\n"
        f"export PATH={shlex.quote(str(prefix / 'bin'))}:\"$PATH\"\n")
    print(version, end="")
    print(f"Activate in your shell: . {shlex.quote(str(environment_file))}")
    print("Rust is pinned by rust-toolchain.toml; validation also needs Python, Node.js and cc.")


if __name__ == "__main__":
    main()
