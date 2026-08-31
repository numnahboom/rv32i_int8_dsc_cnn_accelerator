#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_mac16_stream_adapters"
cd "$root"
rm -rf "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH \
  --Wno-UNUSEDSIGNAL --timing --binary -f sim/filelist_mac16_stream_adapters.f \
  --top-module tb_mac16_stream_adapters --Mdir "$obj"
"$obj/Vtb_mac16_stream_adapters"
