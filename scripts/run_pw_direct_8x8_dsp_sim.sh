#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_pw_direct_8x8_dsp"
cd "$root"
rm -rf "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH \
  --Wno-UNUSEDSIGNAL --timing --binary \
  rtl/cnn/pw_direct_8x8_dsp.v sim/tb_pw_direct_8x8_dsp.v \
  --top-module tb_pw_direct_8x8_dsp --Mdir "$obj"
"$obj/Vtb_pw_direct_8x8_dsp"
