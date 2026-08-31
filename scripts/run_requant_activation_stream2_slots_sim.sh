#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/verilator_requant_activation_stream2_slots"
rm -rf "$build"
mkdir -p "$build"
cd "$root"
verilator --binary --timing --Wno-fatal -Wall \
  --Wno-DECLFILENAME --Wno-WIDTH --Wno-UNUSEDSIGNAL \
  --Wno-SIDEEFFECT --Wno-BLKSEQ --Wno-CASEINCOMPLETE \
  --top-module tb_requant_activation_stream2_slots \
  -f "$root/sim/filelist_requant_activation_stream2_slots.f" \
  -Mdir "$build" -o sim_requant_activation_stream2_slots
"$build/sim_requant_activation_stream2_slots"
