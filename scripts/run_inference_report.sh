#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_DIR="$ROOT/build/reports"

cd "$ROOT"
mkdir -p "$REPORT_DIR"

./scripts/run_sim.sh tb_cnn_top_fullnet_sram_datapath

python3 python/compare_outputs.py \
  "$REPORT_DIR/fullnet_expected_logits.hex" \
  "$REPORT_DIR/fullnet_hw_logits.hex" \
  --bits 8

python3 python/inference_accuracy_perf_report.py \
  --hw-metrics "$REPORT_DIR/tb_cnn_top_fullnet_sram_datapath_metrics.txt" \
  --expected-logits "$REPORT_DIR/fullnet_expected_logits.hex" \
  --hw-logits "$REPORT_DIR/fullnet_hw_logits.hex" \
  --out "$REPORT_DIR/inference_accuracy_perf.md"
