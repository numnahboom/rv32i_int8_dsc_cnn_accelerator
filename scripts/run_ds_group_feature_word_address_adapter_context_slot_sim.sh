#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
obj="build/context_slot_pipeline_20260909"
mkdir -p "$obj"
verilator --binary --timing --Wno-fatal -Wall --build-jobs 8 \
  --top-module tb_ds_group_feature_word_address_adapter_context_slot \
  -f sim/filelist_ds_group_feature_word_address_adapter_context_slot.f \
  -Mdir "$obj" -o sim_ds_group_feature_word_address_adapter_context_slot
"$obj/sim_ds_group_feature_word_address_adapter_context_slot"
