#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! command -v verilator >/dev/null 2>&1; then
  echo "BLOCKED: verilator is required" >&2
  exit 2
fi

python_cmd=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import numpy' >/dev/null 2>&1; then
  python_cmd=python3
elif command -v python.exe >/dev/null 2>&1 && python.exe -c 'import numpy' >/dev/null 2>&1; then
  python_cmd=python.exe
fi
if [[ -z "$python_cmd" ]]; then
  echo "BLOCKED: Python with NumPy is required for the C0 reference" >&2
  exit 2
fi
"$python_cmd" python/ds12_stream_reference.py --out build/ds12_stream_harness
"$python_cmd" python/generate_m11a_nonzero_fixture.py \
  --out build/m11a_nonzero_fixture \
  --report docs/reports/m11a_nonzero_fixture_20260907.md

out="build/m11a_runtime_dw_pw_core"
fixture_dir="build/m11a_nonzero_fixture"
rm -rf "$out"
mkdir -p "$out"
obj="$out/verilator_obj"
verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_m11a_runtime_dw_pw_core \
  --Mdir "$obj" -f sim/filelist_m11a_runtime_dw_pw_core.f --exe --build

run_case() {
  local layer="$1"
  local suffix="$2"
  local -a args=("+LAYER=${layer}")
  if [[ "$suffix" == "random" ]]; then
    args+=("+RANDOM_BP")
  fi
  args+=("+FIXTURE=$fixture_dir")
  set +e
  "$obj/Vtb_m11a_runtime_dw_pw_core" "${args[@]}" | tee "$out/layer${layer}_${suffix}.log"
  local sim_status=${PIPESTATUS[0]}
  set -e
  if [[ "$sim_status" -eq 0 ]] && grep -q "^M11A_LAYER${layer}_NONZERO_FIXTURE_PASS " "$out/layer${layer}_${suffix}.log"; then
    return 0
  fi
  echo "M11A_LAYER${layer}_${suffix}_NONZERO_FIXTURE_MISMATCH status=${sim_status}" >&2
  return 1
}

overall_status=0
if ! run_case 1 no_bp; then overall_status=1; fi
if ! run_case 1 random; then overall_status=1; fi
if ! run_case 2 no_bp; then overall_status=1; fi
if ! run_case 2 random; then overall_status=1; fi

diagnostic="$fixture_dir/nonzero_rtl_diagnostic_report.txt"
rtl_report="docs/reports/m11a_nonzero_fixture_rtl_20260907.md"
if [[ "$overall_status" -eq 0 ]]; then
  gate_status="NONZERO_FIXTURE_RTL_PASS"
else
  gate_status="MISMATCH_CORE_DIAGNOSTIC"
fi
{
  echo "M1.1-A non-zero fixture RTL diagnostic"
  echo "fixture=$fixture_dir"
  for log in "$out"/layer*.log; do
    [[ -f "$log" ]] || continue
    echo "--- $log ---"
    grep -E 'M11A_(DW_TRACE|FIRST_MISMATCH|LAYER)' "$log" || true
  done
} > "$diagnostic"
{
  echo "# M1.1-A non-zero fixture RTL gate"
  echo
  if [[ "$overall_status" -eq 0 ]]; then
    echo "Status: \`$gate_status\`. The independent fixture/reference and the current standalone core pass the non-zero arithmetic gate."
  else
    echo "Status: \`$gate_status\`. The independent fixture/reference passed; the current standalone core does not pass the non-zero arithmetic gate."
  fi
  echo
  echo "The run covers DS1/DS2 with no backpressure and randomized memory/output backpressure. The testbench still checks sink bytes, address/context/owner/epoch/last metadata, config count, DW/PW MAC/token/output ledgers, and error=0."
  echo
  echo "## Latest first mismatches and ledgers"
  echo
  echo "| Case | First mismatch (word/address) | Expected -> actual | Cycles | Outputs | DW vectors/MAC | PW tokens/MAC | Stalls | error |"
  echo "|---|---|---|---:|---:|---:|---:|---:|---:|"
  for log in "$out"/layer*.log; do
    [[ -f "$log" ]] || continue
    line=$(grep -m1 'M11A_FIRST_MISMATCH' "$log" || true)
    summary=$(grep -m1 'M11A_LAYER' "$log" || true)
    if [[ -n "$summary" ]]; then
      case_name=$(basename "$log" .log)
      if [[ -n "$line" ]]; then
        mismatch=$(echo "$line" | sed -E 's/.*word=([0-9]+) addr_exp=([^ ]+) addr_act=([^ ]+) data_exp=([^ ]+) data_act=([^ ]+).*/word=\1 addr=\2 expected=\4 actual=\5/')
      else
        mismatch="none"
      fi
      cycles=$(echo "$summary" | sed -E 's/.*cycles=([0-9]+).*/\1/')
      out_words=$(echo "$summary" | sed -E 's/.* out=([0-9]+) dw_vec=.*/\1/')
      dw_ledger=$(echo "$summary" | sed -E 's/.*dw_vec=([0-9]+) dw_mac=([0-9]+).*/\1\/\2/')
      pw_ledger=$(echo "$summary" | sed -E 's/.*pw_tokens=([0-9]+) pw_mac=([0-9]+).*/\1\/\2/')
      stalls=$(echo "$summary" | sed -E 's/.*stalls=([0-9]+).*/\1/')
      error_code=$(echo "$summary" | sed -E 's/.*error=([^ ]+).*/\1/')
      echo "| $case_name | $mismatch | | $cycles | $out_words | $dw_ledger | $pw_ledger | $stalls | $error_code |"
    fi
  done
  echo
  if [[ "$overall_status" -eq 0 ]]; then
    echo "All four DS1/DS2 cases passed with non-zero fixture data, including randomized memory/output backpressure."
  else
    echo "At least one case reported a first mismatch; inspect the per-case rows and the diagnostic trace above."
  fi
  echo
  echo "This is standalone M1.1-A evidence only, not full-network/full-top evidence."
} > "$rtl_report"

if [[ "$overall_status" -ne 0 ]]; then
  echo "M11A_RUNTIME_DW_PW_NONZERO_FIXTURE_MISMATCH"
  exit "$overall_status"
fi
echo "M11A_RUNTIME_DW_PW_NONZERO_FIXTURE_PASS"
