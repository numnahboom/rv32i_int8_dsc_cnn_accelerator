#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import numpy' >/dev/null 2>&1; then py=python3
elif command -v python.exe >/dev/null 2>&1 && python.exe -c 'import numpy' >/dev/null 2>&1; then py=python.exe
else echo 'BLOCKED: Python with NumPy is required' >&2; exit 2; fi
"$py" python/ds12_stream_reference.py --out build/ds12_stream_harness
command -v verilator >/dev/null 2>&1 || { echo 'BLOCKED: verilator is required' >&2; exit 2; }
obj="build/ds12_stream_harness/verilator_ds1_dw_endpoint"
rm -rf "$obj"
verilator --binary --timing --Wall --Wno-fatal --top-module tb_ds12_stream_ds1_dw_endpoint \
  --Mdir "$obj" -f sim/filelist_ds12_stream_ds1_dw_endpoint.f --exe --build
"$obj/Vtb_ds12_stream_ds1_dw_endpoint"
