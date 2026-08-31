#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_dw_pw_spatial_block_buffer_lutram"
cd "$root"
rm -rf "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH \
  --Wno-UNUSEDSIGNAL --timing --binary \
  rtl/cnn/dw_pw_spatial_block_buffer_lutram.v \
  sim/tb_dw_pw_spatial_block_buffer_lutram.v \
  -Isim \
  --top-module tb_dw_pw_spatial_block_buffer --Mdir "$obj"
"$obj/Vtb_dw_pw_spatial_block_buffer"
