#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
command -v verilator >/dev/null 2>&1 || { echo 'BLOCKED: verilator is required' >&2; exit 2; }
obj="build/ds12_stream_harness/verilator_ds2_pw_consumer_protocol"
rm -rf "$obj"
verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_ds12_stream_ds2_pw_consumer_protocol \
  --Mdir "$obj" -f sim/filelist_ds12_stream_ds2_pw_consumer_protocol.f --exe --build
"$obj/Vtb_ds12_stream_ds2_pw_consumer_protocol"
