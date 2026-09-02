#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/verilator_edgembconv_hwacandidate_d4_dsp_pool"
mkdir -p "$out"
# WSL images used for RTL simulation may not carry numpy, while the
# workspace's Windows Python runtime does. Select a numpy-capable exporter
# without changing the independent D4 vector directory.
if python3 -c 'import numpy' >/dev/null 2>&1; then
  python3 "$root/python/export_edgembconv_hwacandidate_d4_dsp_pool_vectors.py"
elif command -v python.exe >/dev/null 2>&1; then
  # Windows Python needs a Windows path when invoked from WSL.
  python.exe "$(wslpath -w "$root/python/export_edgembconv_hwacandidate_d4_dsp_pool_vectors.py")"
else
  echo "ERROR: no Python runtime with numpy is available for D4 vector export" >&2
  exit 1
fi
verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_edgembconv_hwacandidate_d4_dsp_pool \
  -f "$root/sim/filelist_edgembconv_hwacandidate_d4_dsp_pool.f" \
  --Mdir "$out" -o sim_edgembconv_hwacandidate_d4_dsp_pool
"$out/sim_edgembconv_hwacandidate_d4_dsp_pool"
