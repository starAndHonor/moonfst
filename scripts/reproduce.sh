#!/usr/bin/env bash
# Use scripts/bootstrap.py first if the pinned MoonBit toolchain is not installed.
set -euo pipefail
moonfst_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$moonfst_root"
case "${1:-}" in
  ""|--bench) ;;
  *) printf 'Usage: bash scripts/reproduce.sh [--bench]\n' >&2; exit 2 ;;
esac
bash scripts/check.sh
if [[ "${1:-}" == --bench ]]; then
  moonfst_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  python3 scripts/benchmark.py --output "artifacts/benchmarks/synthetic-$moonfst_stamp"
  python3 scripts/workload_benchmark.py \
    --sizes 10000 100000 200000 --orders sorted shuffled \
    --samples 7 --warmups 2 --rounds 3 --memory-rounds 3 \
    --output "artifacts/benchmarks/real-$moonfst_stamp"
fi
