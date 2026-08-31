#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/verilator_ds_dw_requant_stream4_write_adapter_local"
rm -rf "$build"
mkdir -p "$build"
verilator --binary --timing --Wno-fatal -Wall \
  --top-module tb_ds_dw_requant_stream4_write_adapter_local \
  -f "$root/sim/filelist_ds_dw_requant_stream4_write_adapter_local.f" \
  -Mdir "$build" -o sim_ds_dw_requant_stream4_write_adapter_local
"$build/sim_ds_dw_requant_stream4_write_adapter_local"
