#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
obj="$root/build/verilator_cnn_fullnet_shared_persistent_ds"
mkdir -p "$obj"
verilator --binary --timing --top-module tb_cnn_top_fullnet_sram_datapath \
  -DDEBUG_SHARED_FULLNET \
  -GUSE_SHARED_UNIFIED64=1 -GUSE_UNIFIED64_STEM=0 -GUSE_UNIFIED64_DS=0 \
  -GUSE_PERSISTENT_DS=1 --Mdir "$obj" --build-jobs 8 -Wno-fatal \
  -Wno-DECLFILENAME -Wno-WIDTH -Wno-UNSIGNED \
  -f "$root/sim/filelist_cnn_current.f" \
  "$root/sim/tb_cnn_top_fullnet_sram_datapath.v" \
  -o sim_cnn_fullnet_shared_persistent_ds
"$obj/sim_cnn_fullnet_shared_persistent_ds"
hw_hash=$(sha256sum "$root/build/reports/fullnet_hw_logits.hex" | awk '{print $1}')
expected_hash=$(sha256sum "$root/build/reports/fullnet_expected_logits.hex" | awk '{print $1}')
printf 'SHA256 hw=%s expected=%s\n' "$hw_hash" "$expected_hash"
if [[ "$hw_hash" != "$expected_hash" ]]; then
  printf 'FAIL fullnet logits SHA256 mismatch\n' >&2
  exit 1
fi
