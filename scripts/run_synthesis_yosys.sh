#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/reports

REPORT=build/reports/synthesis_initial.md
DOC_REPORT=docs/synthesis_initial.md
LOG=build/reports/yosys_cnn_top.log

{
  echo "# Initial Synthesis Report"
  echo
  echo "- Date: $(date -Iseconds)"
  echo "- Top module: \`cnn_top\`"
  echo "- Script: \`scripts/yosys_cnn_top.ys\`"
  echo
} > "${REPORT}"

if ! command -v yosys >/dev/null 2>&1; then
  {
    echo "## Status"
    echo
    echo "\`yosys\` was not found in PATH, so no post-synthesis cell/resource numbers were produced on this machine."
    echo
    echo "This is a real tool-run attempt, not a fabricated synthesis result. Install Yosys, then rerun:"
    echo
    echo "\`\`\`bash"
    echo "cd /mnt/d/Stuff/Project"
    echo "./scripts/run_synthesis_yosys.sh"
    echo "\`\`\`"
    echo
    echo "Expected outputs after a successful run:"
    echo
    echo "- \`build/reports/yosys_cnn_top.log\`"
    echo "- \`build/reports/yosys_cnn_top_stat.txt\`"
    echo "- \`build/reports/cnn_top_yosys.json\`"
  } >> "${REPORT}"
  cp "${REPORT}" "${DOC_REPORT}"
  cat "${REPORT}"
  exit 0
fi

YOSYS_VERSION=$(yosys -V)
{
  echo "## Tool"
  echo
  echo "- ${YOSYS_VERSION}"
  echo
} >> "${REPORT}"

yosys -l "${LOG}" scripts/yosys_cnn_top.ys

{
  echo "## Generated Artifacts"
  echo
  echo "- \`${LOG}\`"
  echo "- \`build/reports/yosys_cnn_top_stat.txt\`"
  echo "- \`build/reports/cnn_top_yosys.json\`"
  echo
  echo "## Statistics"
  echo
  echo "\`\`\`text"
  sed -n '/=== cnn_top ===/,$p' build/reports/yosys_cnn_top_stat.txt
  echo "\`\`\`"
} >> "${REPORT}"

cp "${REPORT}" "${DOC_REPORT}"
cat "${REPORT}"
