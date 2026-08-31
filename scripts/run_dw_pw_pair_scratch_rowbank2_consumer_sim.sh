#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_dw_pw_pair_scratch_rowbank2_consumer"
cd "$root"
mkdir -p "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH --build-jobs 8 \
  --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT --Wno-BLKSEQ --timing --binary \
  -f sim/filelist_dw_pw_pair_scratch_rowbank2_consumer.f \
  --top-module tb_dw_pw_pair_scratch_rowbank2_consumer --Mdir "$obj"
"$obj/Vtb_dw_pw_pair_scratch_rowbank2_consumer"
