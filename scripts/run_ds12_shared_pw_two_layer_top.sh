#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/ds12_shared_pw"
random_out="$root/build/ds12_shared_pw_random"

if command -v python3 >/dev/null 2>&1 && python3 -c 'import numpy' >/dev/null 2>&1; then
  py=python3
  py_root="$root"
elif command -v python.exe >/dev/null 2>&1 && python.exe -c 'import numpy' >/dev/null 2>&1; then
  py=python.exe
  # Windows Python cannot consume a WSL /mnt path directly; pass it the
  # translated checkout path while keeping Verilator outputs in WSL paths.
  if command -v wslpath >/dev/null 2>&1; then
    py_root="$(wslpath -w "$root")"
  else
    py_root="$root"
  fi
else
  echo "BLOCKED: Python with NumPy is required for the C0 reference" >&2
  exit 2
fi

"$py" "$py_root/python/ds12_stream_reference.py" --out "$py_root/build/ds12_stream_harness"
rm -rf "$out/obj" "$random_out/obj"
mkdir -p "$out/obj" "$random_out/obj"
verilator --binary --timing --Wno-fatal \
  --top-module tb_ds12_shared_pw_two_layer_top \
  --Mdir "$out/obj" -f "$root/sim/filelist_ds12_shared_pw_two_layer_top.f" \
  --build >"$out/verilator_build.log" 2>&1
"$out/obj/Vtb_ds12_shared_pw_two_layer_top" | tee "$out/no_bp.log"

verilator --binary --timing --Wno-fatal -DTB_RANDOM_BP \
  --top-module tb_ds12_shared_pw_two_layer_top \
  --Mdir "$random_out/obj" -f "$root/sim/filelist_ds12_shared_pw_two_layer_top.f" \
  --build >"$random_out/verilator_build.log" 2>&1
"$random_out/obj/Vtb_ds12_shared_pw_two_layer_top" | tee "$random_out/random_bp.log"
