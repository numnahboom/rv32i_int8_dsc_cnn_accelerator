#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/verilator_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool"
mkdir -p "$out"
if [[ ! -f "$root/build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_acc.mem" ]]; then
  if python3 -c 'import numpy' >/dev/null 2>&1; then
    python3 "$root/python/export_edgembconv_hwacandidate_d4_dsp_pool_vectors.py"
  elif command -v python.exe >/dev/null 2>&1; then
    python.exe "$(wslpath -w "$root/python/export_edgembconv_hwacandidate_d4_dsp_pool_vectors.py")"
  else
    echo "ERROR: D4 real vector export requires numpy-capable Python" >&2
    exit 1
  fi
fi
verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool \
  -f "$root/sim/filelist_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool.f" \
  --Mdir "$out" -o sim_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool
"$out/sim_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool"
