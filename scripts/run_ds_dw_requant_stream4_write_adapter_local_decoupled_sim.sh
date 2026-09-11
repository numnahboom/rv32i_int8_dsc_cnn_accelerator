#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
build="$root/build/verilator_ds_dw_requant_stream4_write_adapter_local_decoupled"
rm -rf "$build"
mkdir -p "$build"
verilator --binary --timing --Wno-fatal -Wall \
  --top-module tb_ds_dw_requant_stream4_write_adapter_local_decoupled \
  -f "$root/sim/filelist_ds_dw_requant_stream4_write_adapter_local_decoupled.f" \
  -Mdir "$build" -o sim_ds_dw_requant_stream4_write_adapter_local_decoupled
"$build/sim_ds_dw_requant_stream4_write_adapter_local_decoupled"
