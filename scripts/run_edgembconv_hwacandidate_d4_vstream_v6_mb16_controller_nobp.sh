#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/verilator_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_nobp"
mkdir -p "$out"
verilator --binary --build-jobs 8 --timing --Wall --Wno-fatal --Wno-BLKLOOPINIT --Wno-UNOPTFLAT \
  -DV6_NO_BACKPRESSURE --top-module tb_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller \
  -f "$root/sim/filelist_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller.f" \
  --Mdir "$out" -o sim_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_nobp
"$out/sim_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_nobp"
