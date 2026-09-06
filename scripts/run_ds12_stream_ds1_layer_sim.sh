#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/ds12_stream_harness"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import numpy' >/dev/null 2>&1; then py=python3
elif command -v python.exe >/dev/null 2>&1 && python.exe -c 'import numpy' >/dev/null 2>&1; then py=python.exe
else echo "BLOCKED: Python with NumPy is required" >&2; exit 2; fi
cd "$root"
"$py" python/ds12_stream_reference.py --out build/ds12_stream_harness
if ! command -v verilator >/dev/null 2>&1; then echo "BLOCKED: verilator is required" >&2; exit 2; fi
obj="$out/verilator_ds1_layer_obj"
rm -rf "$obj"
defines=()
if [[ "${DS12_NO_BP:-0}" == "1" ]]; then defines+=("-DDS12_NO_BP"); fi
verilator --binary --timing --Wall --Wno-fatal "${defines[@]}" --top-module tb_ds12_stream_ds1_layer --Mdir "$obj" -f "$root/sim/filelist_ds12_stream_ds1_layer.f" --exe --build
"$obj/Vtb_ds12_stream_ds1_layer"
