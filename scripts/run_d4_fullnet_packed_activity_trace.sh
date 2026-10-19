#!/usr/bin/env bash
set -euo pipefail
trace_script="$(realpath "${BASH_SOURCE[0]}")"
cd "$(dirname "$trace_script")/.."
repo_root="$PWD"
out="$repo_root/build/verilator_d4_fullnet_packed_trace_${D4_RUN_TAG:-current}"
logs="$repo_root/build/reports/d4_fullnet_${D4_RUN_TAG:-affine_packed_20261018}"
source_root="$(realpath "${D4_SOURCE_ROOT:-$repo_root}")"
work_root="$(realpath "${D4_WORKING_ROOT:-$repo_root}")"
testbench="${D4_TB_SOURCE:-$source_root/sim/tb_d4_fullnet_packed.sv}"
if [[ ! -f "$testbench" ]]; then
    echo "Missing frozen testbench: $testbench (set D4_TB_SOURCE explicitly)" >&2
    exit 1
fi
testbench="$(realpath "$testbench")"
mkdir -p "$out" "$logs"
sha256sum "$source_root/rtl/cnn/d4_fullnet_clocking.sv" \
    "$source_root/rtl/cnn/d4_fullnet_top.sv" \
    "$source_root/rtl/cnn/d4_fullnet_impl_top.sv" "$testbench" \
    "$trace_script" > "$logs/trace_source_hashes.txt"
# The RTL and testbench use build/d4_fullnet_vectors/sample_0 at runtime.
# Set D4_WORKING_ROOT to the frozen implementation sources to read the exact
# checkpoint ROMs/golden vectors without writing logs into that source bundle.
sha256sum "$work_root"/build/d4_fullnet_vectors/sample_0/*.mem \
    > "$logs/trace_vector_hashes_before.txt"
cd "$work_root"
verilator --binary --build-jobs "${D4_BUILD_JOBS:-2}" --timing -Wall -Wno-fatal \
    --trace --trace-depth 6 --trace-max-array 128 \
    --top-module tb_d4_fullnet_packed "$source_root/rtl/cnn/d4_fullnet_clocking.sv" \
    "$source_root/rtl/cnn/d4_fullnet_top.sv" \
    "$source_root/rtl/cnn/d4_fullnet_impl_top.sv" "$testbench" \
    --Mdir "$out" -o sim_d4_fullnet_packed_trace > "$logs/trace_compile.log" 2>&1
"$out/sim_d4_fullnet_packed_trace" +mode=0 +epochs=1 \
    +vcd="$logs/inference.vcd" > "$logs/trace_sim.log" 2>&1
sha256sum "$work_root"/build/d4_fullnet_vectors/sample_0/*.mem \
    > "$logs/trace_vector_hashes_after.txt"
cmp "$logs/trace_vector_hashes_before.txt" "$logs/trace_vector_hashes_after.txt"
grep D4_PACKED_FULLNET_PASS "$logs/trace_sim.log"
