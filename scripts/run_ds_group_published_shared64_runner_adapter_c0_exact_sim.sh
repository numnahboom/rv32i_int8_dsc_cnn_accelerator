#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
python3 python/generate_shared64_c0_exact_fixture.py --out build/shared64_c0_exact
mkdir -p build/reports
obj="build/verilator_ds_group_published_shared64_runner_adapter_c0_exact"
rm -rf "$obj"
verilator --binary --timing --Wno-fatal -Wall --build-jobs 8 \
  --top-module tb_ds_group_published_shared64_runner_adapter_c0_exact \
  -f sim/filelist_ds_group_published_shared64_runner_adapter_c0_exact.f \
  -Mdir "$obj" -o sim_ds_group_published_shared64_runner_adapter_c0_exact
"$obj/sim_ds_group_published_shared64_runner_adapter_c0_exact"
