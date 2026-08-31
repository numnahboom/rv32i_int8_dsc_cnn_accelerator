#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_dw_pw_pair_scratch_bank"
cd "$root"
rm -rf "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH \
  --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT --Wno-BLKSEQ --timing --binary \
  -f sim/filelist_dw_pw_pair_scratch_bank.f \
  --top-module tb_dw_pw_pair_scratch_bank --Mdir "$obj"
"$obj/Vtb_dw_pw_pair_scratch_bank"
