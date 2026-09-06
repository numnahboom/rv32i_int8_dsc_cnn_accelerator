#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import numpy' >/dev/null 2>&1; then py=python3
elif command -v python.exe >/dev/null 2>&1 && python.exe -c 'import numpy' >/dev/null 2>&1; then py=python.exe
else echo 'BLOCKED: Python with NumPy is required' >&2; exit 2; fi
"$py" python/ds12_stream_reference.py --out build/ds12_stream_harness
command -v verilator >/dev/null 2>&1 || { echo 'BLOCKED: verilator is required' >&2; exit 2; }
out="build/ds12_stream_ds2_dw_compute"
obj="$out/verilator"
mkdir -p "$out"
rm -rf "$obj"
verilator --binary --timing --Wall --Wno-fatal --top-module tb_ds12_stream_ds2_dw_compute \
  --Mdir "$obj" -f sim/filelist_ds12_stream_ds2_dw_compute.f --exe --build \
  2>&1 | tee "$out/verilator_build.log"
"$obj/Vtb_ds12_stream_ds2_dw_compute" 2>&1 | tee "$out/run.log"
grep -q '^DS12_DS2_DW_COMPUTE_PASS ' "$out/run.log"
echo "PASS report=$out/run.log"
