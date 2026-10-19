# D4 activity-driven power annotation

`python/d4_activity_power.py` streams a Verilator VCD into SAIF. It selects
`TOP.tb_d4_fullnet.dut` and maps that scope onto
`d4_fullnet_impl_top/u_core`, which is the core instance in the implementation
top. The converter writes each vector bit as its own SAIF entry, preserves the
VCD time unit and duration, and emits the source, SAIF, and converter hashes in
JSON metadata. Vivado's `vcd2saif` utility was not present in the installed
Vivado 2025.2 tree, so this flow uses the standard-library converter.

For the packed physical-top trace, use source scope
`TOP.tb_d4_fullnet_packed.dut` and target scope `d4_fullnet_impl_top`. This
maps the whole selected physical top, including packer-level nets and nested
`u_core`, under the single `DESIGN d4_fullnet_impl_top` SAIF root. The wrapper
accepts these overrides as `-VcdRoot` and `-TargetRoot`; the converter accepts
them as `--vcd-root` and `--target-root`. The current packed trace is
`build/reports/d4_fullnet_affine_packed_deep_20261018/inference.vcd`, built from the
immutable source snapshot at
`build/reports/d4_fullnet_route_affine_packed_20261018/sources`. Pass that directory as
`-SourceRoot` to hash those RTL/XDC files. This records provenance but does not
verify the DCP-to-source relationship; an upstream manifest must be checked
independently for that claim.

For a future timing-accepted candidate, the packed trace helper accepts
`D4_SOURCE_ROOT` for frozen RTL/testbench and `D4_WORKING_ROOT` for runtime
ROM, input and golden files. Set both to its implementation `sources/` bundle.
New implementation snapshots include the packed testbench; older bundles
require an explicit frozen `D4_TB_SOURCE`. Build outputs and logs remain under
the repository `build/` tree. The helper records every runtime `.mem` hash
before and after simulation and rejects a change. Its mocked invocation test
checks path handling only and supplies no production waveform evidence.

After the matching routed checkpoint exists, run the complete annotation and
power flow from the repository root. The concrete paths below are an earlier
core-level smoke example; final evidence must use the packed trace and routed
checkpoint from the same source snapshot, with the root overrides above:

```powershell
.\scripts\run_d4_activity_power.ps1 `
  -Vcd build/reports/d4_fullnet_cursor_20261018/inference.vcd `
  -Dcp build/reports/d4_fullnet_route_20261018/routed.dcp `
  -SimulationLog build/reports/d4_fullnet_cursor_20261018/trace_sim.log `
  -SourceRoot build/reports/d4_fullnet_synth_regout_20261018/sources `
  -OutDir build/reports/d4_fullnet_activity_20261018
```

The output directory contains `activity.saif`, `activity_metadata.json`,
`saif_annotation_messages.txt`, `switching_activity_after_saif.txt`,
`top_level_port_activity_assignments.tsv`, and `power_after_saif_annotation.txt`,
along with the checkpoint route and annotation-scope reports. The metadata hashes the routed checkpoint, VCD,
SAIF, converter, Tcl, wrapper, the RTL and XDC under `-SourceRoot`, optional
simulation log, and generated reports. `-SourceRoot` defaults to the repository
root and should point to a source snapshot when the routed checkpoint was built
from one. The metadata records this path and explicitly marks the DCP-to-source
relationship as unverified unless independently checked against an upstream
manifest.
The Tcl opens the supplied checkpoint and runs `read_saif -strip_path` with the
implementation top name, retaining the nested instance hierarchy written into SAIF. It also writes the checkpoint
route status so the report's physical stage can be checked.

The metadata's residency summary describes the selected VCD scope only. It is
not a percentage of routed nets successfully annotated. Check the SAIF import
messages and Vivado switching-activity report for mapping and coverage, and use
Vivado's confidence and static/dynamic power rows from the separate power
report. Any unannotated nets can still use Vivado's vectorless activity
propagation. This is a post-implementation Vivado estimate, not board-measured
power. `power_after_saif_annotation.txt` describes the estimate after SAIF
annotation; it does not claim that every net's activity came from SAIF.

The native Tcl first imports the source SAIF unchanged, then builds
`fd_q_alias.saif` from exact original-name FD-cell Q aliases found in the
routed checkpoint. Each alias uses the physical net's Vivado `NAME`, so
synthesis-renamed FD Q nets receive the source bit's original `T0`, `T1`,
`TX`, `TZ`, and `TC` counts. The Tcl imports this alias file with one separate
`read_saif` call; it does not infer DSP slices, retimed or replicated names, or
recoded FSM bits. Conflicting source aliases are excluded and counted.

`fd_q_alias_points.tsv` records each source RTL bit, physical net name, and all
five unchanged SAIF statistics. `fd_q_alias_summary.txt` records candidate,
conflict, and unmatched counts. `fd_q_alias_annotation_messages.txt` preserves
Vivado's unmatched-name messages for the alias import. The original-SAIF and
FD-Q-alias `Design nets matched` counts appear separately in
`evidence_summary.json`; do not add them because their overlap is not measured.
`power_after_saif_annotation.txt` reports the final estimate after both
imports, including Vivado's confidence and static/dynamic power. This remains
a post-route estimate, not board-measured power, and unannotated nets may use
Vivado's vectorless propagation. The wrapper also hashes
`rtl/cnn/d4_fullnet_clocking.sv` when present and marks it
`not_applicable_missing` for older source snapshots.

Generated scopes such as `rq_mul_lanes[0]` remain separate nested SAIF
`INSTANCE` records, followed by their child instance (for example `rq_mul`).
The Tcl parser preserves each scope atom and rejects malformed `INSTANCE`
records instead of ignoring the scope and treating child nets as belonging to
its parent. Vivado may return a generated cell path with different punctuation,
so source SAIF names are matched exactly and no slash-to-dot alias is inferred.
The checked-in `tests/fixtures/d4_activity_binding/binding_smoke.saif` is a
small hand-authored unit fixture only. The bounded evidence harness under
`build/reports/d4_activity_binding_20261018/verilator_smoke_native_mock/` uses
the real 14,195-record Verilator SAIF and checks the 16-row table against the
hashed L2 synthesis hierarchy, DCP, source manifest, and frozen core. It mocks
Vivado cell properties from that observed L2 hierarchy; it does not query a
current checkpoint in Vivado.

When a checkpoint retains the observed L2 multiplier hierarchy, the runner can
opt into an explicit FD-Q scope binding:

```powershell
.\scripts\run_d4_activity_power.ps1 `
  -Vcd <trace.vcd> `
  -Dcp <routed.dcp> `
  -HierarchyBindingTsv build/reports/d4_activity_binding_20261018/fd_q_hierarchy_bindings.tsv `
  -OutDir <activity-report>
```

The supplied table must contain the complete 16-row RQ mapping in
`build/reports/d4_activity_binding_20261018/fd_q_hierarchy_bindings.tsv`.
The runner hashes that table together with the observed L2 synthesis hierarchy,
its frozen source manifest, the frozen `d4_fullnet_top.sv`, and the synth
checkpoint. Before creating aliases, Vivado Tcl requires exactly one current
cell for every listed physical `NAME` and checks its
`ORIG_REF_NAME=d4_rq_partial_multiplier_lane` and `PARENT=u_core`. A bounded
TSV records the result for all 16 rows. Only an exact physical-scope prefix
followed by `/` is translated to its paired source-scope prefix while building
eligible FD-Q aliases. The signal leaf and bit index, exact physical net `NAME`,
and all five SAIF statistics remain intact. Other scopes use the original exact
matching path. Omitting `-HierarchyBindingTsv` retains the original exact-name
behavior.

This opt-in is limited to those 16 evidence-backed RQ scopes; it does not infer
slash/dot conversions for other hierarchy names. The real-Verilator-SAIF mock
checks lane 0 and lane 15 `product[0]` statistics unchanged and retains the
mocked physical `NAME` strings in its output. It does not query a current
checkpoint in Vivado, verify a final routed checkpoint natively, or establish
SAIF annotation coverage or power. A later native run must revalidate every row
against the timing-accepted checkpoint before its power result can use this
binding.

For packed-top SAIF, the native Tcl separately sets activity on exact-name,
nonclock `INPUT` ports whose source residency is fully known. It uses the
unchanged SAIF `TC` count as Vivado's absolute `-signal_rate` in
Mtransitions/second (`TC / duration_seconds / 1e6`) and `T1 / DURATION` as
`-static_probability`. Scalar ports and individual bus-bit names use the same
path. Clock ports, outputs, inouts, unmatched names, and input records with
`TX`/`TZ` residency are excluded; skipped unknown activity is reported instead
of filled with an assumed value. The TSV records each source candidate, its
direction, all five source counts, calculated values, and whether a
`set_switching_activity` command was issued. A candidate count by itself is not
annotation coverage; use Vivado's final I/O confidence and power report.

The historical `native_attempt_6_fd_q_alias` run predates these explicit input
assignments. Its 79 exact nonclock port-name candidates are not verified port
annotations. Vivado reported I/O activity confidence **Low**, stating that more
than 75% of inputs were missing user specification. Its 0.546 W result remains
a low-confidence post-route estimate with partial SAIF coverage, not a
125 MHz operating-power or efficiency result. The raw attempt's
`fd_q_alias_summary.txt` is preserved unchanged; its legacy
`top_level_nonclock_ports_annotated_by_original_read_saif=79` label is treated
as a candidate count only and is omitted from the normalized
`evidence_summary.json`.

`native_attempt_7_explicit_input_ports` completed the corrected native path
on the same historical E checkpoint and repaired SAIF: 37/37 nonclock inputs
were assigned using their exact statistics, one clock and 42 outputs were
excluded, and native I/O confidence became High. Overall confidence is Medium;
internal activity remains Medium with less than 25% user-specified internal
nodes. Total power is still 0.546 W (dynamic 0.428 W, static 0.118 W). The two SAIF
import counts remain 816/45,672 and 4,137/45,672 with unknown overlap. Parent
acceptance verified all 37 report hashes and each explicit input formula; see
`build/reports/d4_activity_power_tooling_20261018/parent_native7_acceptance.json`.
E still fails 125 MHz setup, so this validates the annotation tool, not operating
energy or a newer candidate's power. Final power requires a matching new trace
and a timing-accepted checkpoint.

`TC` counts only known `0` to `1` or `1` to `0` transitions. X/Z transitions
are not counted as toggles; their exact residency is retained in `TX` and
`TZ`. By default, SAIF duration ends at the VCD's final timestamp. If the VCD
does not end at the exact simulator stop time, pass the known exact tick count
with `-DurationTicks`.

The standalone converter is also available when only SAIF generation is
needed:

```powershell
python python/d4_activity_power.py `
  --vcd build/reports/d4_fullnet_affine_packed_deep_20261018/inference.vcd `
  --saif build/reports/d4_activity_power_tooling_20261018/inference.activity.saif `
  --metadata build/reports/d4_activity_power_tooling_20261018/inference.activity.json `
  --vcd-root TOP.tb_d4_fullnet_packed.dut `
  --target-root d4_fullnet_impl_top
```

## P 的真实 native 验证（2026-10-19）

当前 helper 已通过 P routed DCP 的实际 native 导入，记录在 `build/reports/d4_p_activity_power_20261019_contract/parent_acceptance.json`。SAIF INSTANCE/NET 字面标识符使用反斜杠转义标点，末尾数值 bus index 保留原语法；双引号不能替代 Vivado SAIF 标识符转义。FD-Q统计及16条明确物理层级绑定保持。wrapper 以 Add-Member 写入 finished_at_utc，避免 native 失败后被元数据错误掩盖。修复后的25项工具测试通过；首次失败和一次native-only成功修正均归档，VCD仅转换一次。

本次125MHz单sample0完整2.070696ms窗口：Total.613W、Medium/IO High、1.269337mJ、18.34886GOPS/W，原20目标未通过。原始1006/45420与alias9112/45420匹配计数分别报告、重叠未知；未标注活动可采用默认传播。不能把SAIF记录数或两次import计数之和当作物理全覆盖。复核native可重用归档activity.saif及commands.json中的direct-native命令，无需重新转换1.29GB VCD。
