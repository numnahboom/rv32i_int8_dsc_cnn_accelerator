#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/wordstream_feasibility"
mkdir -p "$BUILD"
verilator --binary --timing --Wno-fatal \
  --top-module tb_wordstream_feasibility_harness \
  -f "$ROOT/sim/filelist_wordstream_feasibility.f" \
  -Mdir "$BUILD/obj_dir" -o "$BUILD/Vtb_wordstream_feasibility_harness"
"$BUILD/Vtb_wordstream_feasibility_harness"
