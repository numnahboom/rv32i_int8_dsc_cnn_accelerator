#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_native_word_response_pipe"
cd "$root"
rm -rf "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH --Wno-UNUSEDSIGNAL \
  --timing --binary -f sim/filelist_native_word_response_pipe.f \
  --top-module tb_native_word_response_pipe --Mdir "$obj"
"$obj/Vtb_native_word_response_pipe"
