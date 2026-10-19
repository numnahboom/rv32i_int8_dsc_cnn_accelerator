#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
out=build/reports/d4_fullnet_20261018
mkdir -p "$out"
for test in vstream_v6_dw_req_adapter_sim dw16_stream_tile_sim \
    vstream_v6_mb16_controller_nobp vstream_v6_mb16_controller_sim \
    vstream_v6_mb16_controller_finalstall vstream_v6_mb16_controller_two_epoch; do
    bash "scripts/run_edgembconv_hwacandidate_d4_${test}.sh" > "$out/baseline_${test}.log" 2>&1
    tail -n 3 "$out/baseline_${test}.log"
done
