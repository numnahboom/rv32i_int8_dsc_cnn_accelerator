#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_native_word_response_pipe_vector16_shell"
cd "$root"; rm -rf "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH --Wno-UNUSEDSIGNAL --timing --binary \
  -f sim/filelist_native_word_response_pipe_vector16_shell.f --top-module tb_native_word_response_pipe_vector16_shell --Mdir "$obj"
"$obj/Vtb_native_word_response_pipe_vector16_shell"
