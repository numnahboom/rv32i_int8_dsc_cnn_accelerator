#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_ds_block_tile_engine_spatial"
cd "$root"
rm -rf "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH \
  --Wno-UNUSEDSIGNAL --Wno-PINCONNECTEMPTY --timing --binary \
  rtl/cnn/ds_block_tile_engine_spatial.v \
  rtl/cnn/dw_direct_3x3_dsp.v rtl/cnn/ds_spatial_dw_producer_island.v \
  rtl/cnn/dw_pw_spatial_block_buffer_island.v \
  rtl/cnn/dw_pw_spatial_bank_bram.v \
  rtl/cnn/ds_input_tile_buffer_bram.v rtl/cnn/pw_direct_8x8_dsp.v \
  rtl/cnn/requant_activation_vector4_spatial.v rtl/cnn/requant_activation_unit.v \
  rtl/cnn/ds_spatial_pw_consumer_island.v \
  sim/tb_ds_block_tile_engine_spatial.v \
  --top-module tb_ds_block_tile_engine_spatial --Mdir "$obj"
"$obj/Vtb_ds_block_tile_engine_spatial"
