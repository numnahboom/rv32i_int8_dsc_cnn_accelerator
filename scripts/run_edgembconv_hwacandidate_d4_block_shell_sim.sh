#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator_edgembconv_hwacandidate_d4_block_shell"
rm -rf "$obj"
mkdir -p "$obj"
cd "$root"
verilator --timing --binary -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL \
  -f sim/filelist_edgembconv_hwacandidate_d4_block_shell.f \
  sim/tb_edgembconv_hwacandidate_d4_block_shell.v \
  --top-module tb_edgembconv_hwacandidate_d4_block_shell \
  --Mdir "$obj" -o sim_edgembconv_hwacandidate_d4_block_shell
"$obj/sim_edgembconv_hwacandidate_d4_block_shell"
