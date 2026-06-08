#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT"
python3 python/resource_estimate.py --out build/reports/resource_estimate.md
