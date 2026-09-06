#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/ds12_stream_harness"

if command -v python3 >/dev/null 2>&1 && python3 -c 'import numpy' >/dev/null 2>&1; then
  py=python3
elif command -v python.exe >/dev/null 2>&1 && python.exe -c 'import numpy' >/dev/null 2>&1; then
  # The supported Windows checkout commonly has NumPy in Anaconda while the
  # WSL tool image intentionally only carries Verilator.
  py=python.exe
else
  echo "BLOCKED: Python with NumPy is required for the C0 reference" >&2
  exit 2
fi

# Use checkout-relative paths: Windows python.exe does not understand a WSL
# /mnt/... absolute path, but resolves these relative to the shared cwd.
"$py" python/ds12_stream_reference.py --out build/ds12_stream_harness

if ! command -v verilator >/dev/null 2>&1; then
  echo "BLOCKED: verilator is required for the deferred DUT/reference harness" >&2
  exit 2
fi

obj="$out/verilator_obj"
rm -rf "$obj"
defines=()
if [[ "${DS12_STREAM_DUT:-0}" == "1" ]]; then
  defines+=("-DDS12_STREAM_DUT")
  if [[ -n "${DS12_STREAM_DUT_MODULE:-}" ]]; then
    defines+=("-DDS12_STREAM_DUT_MODULE=${DS12_STREAM_DUT_MODULE}")
  fi
fi
sources=()
if [[ -n "${DS12_STREAM_DUT_FILE:-}" ]]; then
  sources+=("$DS12_STREAM_DUT_FILE")
fi
verilator --binary --timing --Wall --Wno-fatal \
  "${defines[@]}" \
  --top-module tb_ds12_stream_harness \
  --Mdir "$obj" \
  -f "$root/sim/filelist_ds12_stream_harness.f" \
  "${sources[@]}" \
  --exe --build

"$obj/Vtb_ds12_stream_harness"
