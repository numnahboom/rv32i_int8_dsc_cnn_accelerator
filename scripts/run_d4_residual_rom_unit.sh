#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
out=build/reports/d4_residual_rom_unit_20261020
mkdir -p "$out"
models=()
for bank in {0..7};do models+=("build/asic_macros/residual/D4RROM${bank}/D4RROM${bank}_sim.v");done
if ! /opt/XCELIUM_2003/tools/bin/xrun -64bit -sv -top tb_d4_residual_roms \
    -xmlibdirname build/xcelium_residual_rom_unit -l "$out/unit.log" \
    rtl/asic/d4_residual_rom_banks.sv "${models[@]}" sim/tb_d4_residual_roms.sv > "$out/console.log" 2>&1;then
    tail -24 "$out/console.log";exit 1
fi
grep '^D4_RESIDUAL_ROM_EXACT_PASS' "$out/unit.log"
