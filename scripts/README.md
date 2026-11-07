# Validation tooling

The current compiler target is MoonBit **`v0.10.20+65efd5b93`**, with
`moon`/`moonrun` **`0.1.20261104`** and the matching compiler core package.
The CI workflow installs the exact compiler/core release through the official
[MoonBit installer](https://cli.moonbitlang.com/install/unix.sh) with
`MOONBIT_INSTALL_VERSION=0.10.20+65efd5b93`. It verifies the resulting version;
it does not install a moving `latest` alias. Future upgrades require updating
the workflow and script version pins and rerunning acceptance checks.

Other validation tools:

| Tool | Requirement / CI version |
|---|---|
| Rust/Cargo | CI: `1.94.1`; `oracle/Cargo.lock` pins dependency versions and hashes |
| Reference crate | Unmodified crates.io **`fst = "=0.4.7"`** |
| Python | Standard library only, Python 3.10+; CI: 3.12 |
| Node.js | Node.js 22; local differential checks also use 22.14.0 |
| Native compiler | `cc` available; CI uses Ubuntu 24.04's compiler |

Run the complete local acceptance sequence:

```sh
bash scripts/check.sh
```

This checks source formatting, the Rust bridge's tests, exact fixture
regeneration, fixture integrity/query/corruption checks, and MoonBit
`check`/`test --deny-warn` on `native`, `js`, `wasm-gc` and `wasm`. It then checks
native binary compatibility in both directions on the 19 committed fixtures
and 64 fixed-seed structured/random cases.

It also runs the benchmark coordinator's protocol and statistics unit tests.
Performance measurements run separately with `python3 scripts/benchmark.py
--output benchmarks/results/my-run`; see [the benchmark methodology](../benchmarks/README.md).
The optional `scripts/plot_benchmark.py` requires Matplotlib; sampling and
statistics use only the Python standard library. Benchmark sources are excluded
from production MoonBit line counts.

The official installer initially bundles Wasm-GC core. `check.sh` explicitly
bundles the matching core for every tested backend. For a custom installation,
set `MOON_HOME` to its root and put its `bin` directory on `PATH`; otherwise the
script uses the installer's standard `~/.moon/lib/core` location.

For additional cross-backend differential checks:

```sh
python3 scripts/interop.py --target native --target js --target wasm-gc
python3 scripts/random_interop.py --target native --target js --target wasm-gc
```

Run these commands sequentially. They temporarily replace the small tracked
integration placeholder with generated fixture embeddings and restore it in a
`finally` block, including on a test failure. Ordinary `moon check`/`moon test`
work on a fresh checkout without running any generator. See
[the integration protocol](../integration/README.md) and
[the Rust oracle protocol](../oracle/README.md).

Source size is reported separately:

```sh
python3 scripts/count_loc.py
python3 scripts/count_loc.py --json
bash scripts/check.sh --min-production-lines=4000
```

The optional minimum is a project preference, **not a verified official
competition threshold**. The default command only reports size. Production
MoonBit counts exclude comments, blank lines, tests, generated data, integration
harnesses, examples, vendored dependency caches and all Rust/Python/shell
tooling. It counts physical nonblank source lines, including delimiters; it
does not claim that line count measures algorithmic complexity or code quality.

`check.sh` records the actual MoonBit/Rust toolchain and machine-readable LOC
report in `oracle/target/validation/`. CI uploads that directory as
`validation-evidence` even when a later acceptance step fails. This records
local evidence; a workflow file alone is not a claim that GitHub CI has run.
