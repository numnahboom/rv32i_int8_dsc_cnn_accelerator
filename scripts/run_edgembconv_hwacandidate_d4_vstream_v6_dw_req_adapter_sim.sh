#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/verilator_edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter"
mkdir -p "$out"
verilator --binary --build-jobs 8 --timing --Wall --Wno-fatal \
  --top-module tb_edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter \
  -f "$root/sim/filelist_edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter.f" \
  --Mdir "$out" -o sim_edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter
"$out/sim_edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter"
