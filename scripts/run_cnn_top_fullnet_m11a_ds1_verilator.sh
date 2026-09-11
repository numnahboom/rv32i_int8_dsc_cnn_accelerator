#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Compatibility entry point retained for callers of the original DS1 name.
# The production branch now covers DS1 and DS2; the canonical runner is the
# DS12-named script below.
exec bash "$root/scripts/run_cnn_top_fullnet_m11a_ds12_verilator.sh" "$@"
