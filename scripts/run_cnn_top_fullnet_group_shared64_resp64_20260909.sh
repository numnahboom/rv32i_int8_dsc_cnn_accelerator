#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
build_root="${VERILATOR_BUILD_ROOT:-build/dw_rq_local_fullnet_20260909_resp64}"
out="$build_root/verilator_cnn_top_fullnet_group_shared64_resp64"
mkdir -p "$out/obj_dir"
verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_cnn_top_fullnet_group_shared64_resp64 \
  -f sim/filelist_cnn_current.f \
  sim/tb_cnn_top_fullnet_sram_datapath.v \
  sim/tb_cnn_top_fullnet_group_shared64_resp64.v \
  --Mdir "$out/obj_dir" -o sim_cnn_top_fullnet_group_shared64_resp64
"$out/obj_dir/sim_cnn_top_fullnet_group_shared64_resp64"
