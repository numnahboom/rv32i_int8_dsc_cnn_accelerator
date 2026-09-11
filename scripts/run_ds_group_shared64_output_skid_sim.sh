#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/verilator_ds_group_shared64_output_skid"
mkdir -p "$out"
cd "$root"
verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_ds_group_shared64_output_skid \
  -f sim/filelist_ds_group_shared64_output_skid.f \
  --Mdir "$out/obj_dir" -o sim_ds_group_shared64_output_skid
"$out/obj_dir/sim_ds_group_shared64_output_skid"
