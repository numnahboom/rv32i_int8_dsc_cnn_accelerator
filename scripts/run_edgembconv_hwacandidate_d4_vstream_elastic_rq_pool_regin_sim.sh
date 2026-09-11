#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/verilator_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin"
mkdir -p "$out"
verilator --binary --build-jobs 8 --timing --Wall --Wno-fatal --Wno-BLKLOOPINIT --Wno-UNOPTFLAT \
  --top-module tb_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin \
  -f "$root/sim/filelist_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin.f" \
  --Mdir "$out" -o sim_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin
"$out/sim_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin"
