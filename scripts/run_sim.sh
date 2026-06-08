#!/usr/bin/env bash
set -euo pipefail

TOP="${1:-tb_requant_activation_unit}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBJ_DIR="$ROOT/build/verilator/$TOP"

cd "$ROOT"

python3 python/generate_test_vectors.py >/dev/null
if [[ "$TOP" == "tb_npc_rv_core_cnn_top_fullnet" ]]; then
  ./scripts/build_firmware_rom.sh >/dev/null
fi

rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR"
mkdir -p "$ROOT/build/reports"

verilator \
  -Wall \
  -Wno-fatal \
  -Wno-DECLFILENAME \
  -Wno-WIDTH \
  -Wno-UNUSEDSIGNAL \
  --timing \
  --binary \
  -Irtl/common \
  -Irtl/cnn \
  -Irtl/cpu_if \
  -Irtl/npc/vsrc \
  -Irtl/npc/vsrc/stages \
  -Irtl/npc/vsrc/hazard \
  -Irtl/npc/vsrc/pip_regs \
  -f sim/filelist.f \
  "sim/${TOP}.v" \
  --top-module "$TOP" \
  --Mdir "$OBJ_DIR"

"$OBJ_DIR/V$TOP" ${RUN_ARGS:-}
