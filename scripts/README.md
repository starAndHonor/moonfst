# Validation tooling

Run these commands from a source checkout. The Mooncakes `starAndHonor/fst`
archive excludes `scripts/`, `oracle/`, `benchmarks/`, external fixtures and
cross-language integration harnesses; the library, its unit tests, examples
and license/architecture documentation remain available in the archive.

The pinned compiler is MoonBit **`v0.10.20+65efd5b93`**, with `moon`/`moonrun` **`0.1.20261104`** and matching core. `toolchain.json` records fixed, URL-encoded official archive URLs and SHA256 digests. Both CI and local setup use `python3 scripts/bootstrap.py`, followed by `. artifacts/env.sh` locally. No moving installer or `latest` archive is executed. See [REPRODUCING.md](../REPRODUCING.md) for prerequisites, a clean-checkout recipe, caches and offline limits.
Other validation tools:

| Tool | Requirement / CI version |
|---|---|
| Rust/Cargo | CI: `1.94.1`; `oracle/Cargo.lock` pins dependency versions and hashes |
| Reference crate | Unmodified crates.io **`fst = "=0.4.7"`** |
| Python | Standard library only, Python 3.12+; CI: 3.12 |
| Node.js | Node.js 22; local differential checks also use 22.14.0 |
| Native compiler | `cc` available; CI uses Ubuntu 24.04's compiler |
| Operating system | Linux for the workload smoke and RSS measurements; the library itself supports all four tested backends |

Run the complete local acceptance sequence:

```sh
bash scripts/check.sh
```

This checks source formatting, the Rust bridge's tests, exact fixture
regeneration, fixture integrity/query/corruption checks, and MoonBit
`check`/`test --deny-warn` on `native`, `js`, `wasm-gc` and `wasm`. It then checks
native binary compatibility in both directions on the 19 committed fixtures
and 64 fixed-seed structured/random cases.

It also runs **27 standard-library Python tests**: 16 synthetic benchmark
protocol/statistics tests and 11 real-workload preparation/protocol tests.
These cover frozen wire/checksum vectors, corpus integrity, query order,
invalid results/times and RSS payload validation without collecting performance
samples or downloading the real corpus:

```sh
python3 -m unittest scripts/test_benchmark.py scripts/test_workload_benchmark.py
```

The acceptance command then runs the offline-data workload smoke:

```sh
python3 scripts/workload_smoke.py
```

This builds both native release runners and uses six manually encoded UTF-8
records, including a supplementary-plane character. It checks sorted and
shuffled queries, mixed hits/misses, all four memory modes and byte-identical
output. No Jieba download is needed. To run with networking disabled, install
the toolchains and cache Cargo dependencies first. This is a correctness check;
the tiny workload's timings are not performance evidence. Its inputs and
results stay under ignored `oracle/target/validation/workload-smoke/`.

Performance measurements run separately:

```sh
python3 scripts/benchmark.py --output artifacts/benchmarks/my-run
python3 scripts/workload_benchmark.py \
  --sizes 10000 100000 200000 --orders sorted shuffled \
  --samples 7 --warmups 2 --rounds 3 --memory-rounds 3 \
  --output artifacts/benchmarks/my-real-run
```

Use a fresh output directory for each measurement. See
[the benchmark methodology](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/README.md)
and the completed
[real-dictionary baseline](https://github.com/starAndHonor/moonfst/blob/main/benchmarks/results/real-baseline-v1/REPORT.md).
The baseline describes its own recorded source fingerprint, not later changes.
The optional `scripts/plot_benchmark.py` requires Matplotlib; sampling and
statistics use only the Python standard library. Benchmark sources are excluded
from production MoonBit line counts.

The real workload is pinned by revision and SHA256 in
[`benchmarks/corpora/`](https://github.com/starAndHonor/moonfst/tree/main/benchmarks/corpora).
It samples Jieba dictionary entries and keeps their original frequencies;
query order is controlled separately. Each word is requested once, misses
append `FF`, and mixed requests alternate hits/misses. These are controlled
queries over real words, not observed traffic or frequency-weighted requests.
Downloads and prepared binary inputs stay in ignored `benchmarks/data/`.

Linux RSS phases run in separate processes. `VmRSS` and `VmHWM` include the
runtime, retained input representations and allocator behavior; the high-water
mark can originate during preparation. Snapshots distinguish the operation
from later content validation. Load starts from exported bytes, with no corpus
construction in that process; MoonBit validates the complete reachable graph,
whereas the Rust reference opens the map and checks CRC. The two load phases
therefore perform different work. Fresh processes do not imply cold OS caches.
The native-only C helper in `src/benchmarks/workload/io.c` performs file I/O and
Linux RSS reads for development tools. It is excluded from the published
archive; the FST library remains pure MoonBit without Rust/C bindings.

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
[the integration protocol](https://github.com/starAndHonor/moonfst/blob/main/src/integration/README.md) and
[the Rust oracle protocol](https://github.com/starAndHonor/moonfst/blob/main/oracle/README.md).

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

The acceptance sequence also runs `python3 scripts/verify_package.py`: actual archive boundaries, four-backend archive tests, the dictionary example, and a four-backend consumer of the extracted archive. It never publishes. CI then rejects changes to tracked files.

Historical decoder diagnostics (`query_ablation.py`, `query_cost_counts.py`) require the pre-optimization revision recorded in their report and explicitly reject the current packed lookup implementation. Native profiling needs a release benchmark build first plus Linux binutils/gprof; it writes new results under ignored `artifacts/profiles/`. These optional diagnostics are not acceptance or performance evidence by themselves.
