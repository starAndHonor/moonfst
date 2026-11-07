#!/usr/bin/env bash
# Validated toolchain target: moonc v0.10.20+65efd5b93, moon 0.1.20261104.
# CI installs that exact version and matching core. An intentional toolchain
# upgrade can override MOONFST_EXPECTED_MOONC_VERSION after validation.
# Rust is pinned by CI and Cargo.lock; scripts need Python 3.10+ and Node.js 22.
set -euo pipefail

moonfst_minimum_loc=0
for moonfst_argument in "$@"; do
  case "$moonfst_argument" in
    --min-production-lines=*) moonfst_minimum_loc="${moonfst_argument#*=}" ;;
    --help)
      printf 'Usage: bash scripts/check.sh [--min-production-lines=4000]\n'
      printf 'The optional threshold is a project preference, not an official contest rule.\n'
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "$moonfst_argument" >&2; exit 2 ;;
  esac
done
if [[ ! "$moonfst_minimum_loc" =~ ^[0-9]+$ ]]; then
  printf 'The production-line threshold must be a nonnegative integer.\n' >&2
  exit 2
fi

moonfst_project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$moonfst_project_root"

for moonfst_tool in moon cargo python3 node cc; do
  if ! command -v "$moonfst_tool" >/dev/null 2>&1; then
    printf 'Required validation tool is missing: %s\n' "$moonfst_tool" >&2
    exit 1
  fi
done

mkdir -p oracle/target/validation
moon version --all | tee oracle/target/validation/moon-toolchain.txt
cargo --version | tee oracle/target/validation/rust-toolchain.txt
python3 --version
node --version
python3 scripts/count_loc.py --json > oracle/target/validation/loc.json
moonfst_expected_version="${MOONFST_EXPECTED_MOONC_VERSION:-0.10.20+65efd5b93}"
moonfst_actual_version="$(cat oracle/target/validation/moon-toolchain.txt)"
if [[ "$moonfst_actual_version" != *"moonc v${moonfst_expected_version}"* ]]; then
  printf 'Expected moonc v%s; the installed toolchain differs.\n' \
    "$moonfst_expected_version" >&2
  exit 1
fi

# The committed integration placeholder compiles without running a generator.
# Check formatting before the scripts temporarily embed their large test data.
moon fmt --check
cargo test --locked --manifest-path oracle/Cargo.toml
python3 -m unittest scripts/test_benchmark.py scripts/test_workload_benchmark.py
python3 scripts/generate_fixtures.py --check
python3 scripts/verify_oracle.py

for moonfst_target in native js wasm-gc wasm; do
  # The official installer initially bundles only Wasm-GC core. Other backends
  # need their matching core interfaces before project compilation.
  moonfst_core_directory="${MOON_HOME:-${HOME}/.moon}/lib/core"
  moon -C "$moonfst_core_directory" bundle --target "$moonfst_target" --warn-list -a --quiet
  moon check --target "$moonfst_target" --deny-warn
  moon test --target "$moonfst_target" --deny-warn
done

# Both directions must use real independent decoders and verify checksums.
python3 scripts/interop.py --target native
python3 scripts/random_interop.py --target native
python3 scripts/workload_smoke.py

python3 scripts/count_loc.py --minimum-production "$moonfst_minimum_loc"
printf 'All validation checks passed. LOC report: oracle/target/validation/loc.json\n'
