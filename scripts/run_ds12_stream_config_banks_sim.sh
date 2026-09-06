#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/verilator_ds12_stream_config_banks"
mkdir -p "$root/build/ds12_stream_harness"
cd "$root"

# The harness words are generated from the checked-in C0 INT8 export.  Keep
# this step explicit so a simulation cannot accidentally use stale vectors.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import numpy' >/dev/null 2>&1; then
  py=python3
elif command -v python.exe >/dev/null 2>&1 && python.exe -c 'import numpy' >/dev/null 2>&1; then
  py=python.exe
else
  echo "BLOCKED: Python with NumPy is required to generate real DS1/DS2 words" >&2
  exit 2
fi
"$py" python/ds12_stream_reference.py --out build/ds12_stream_harness

rm -rf "$out"
verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_ds12_stream_config_banks \
  --Mdir "$out" -f "$root/sim/filelist_ds12_stream_config_banks.f" \
  --exe --build
"$out/Vtb_ds12_stream_config_banks"
