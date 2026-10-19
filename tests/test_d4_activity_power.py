import csv
import json
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))

from d4_activity_power import VcdError, convert_vcd_to_saif, main, parse_vcd


def write_vcd(path: Path, body: str) -> Path:
    path.write_text(body, encoding="ascii")
    return path


def write_tcl_alias_harness(
    tmp_path: Path,
    source_saif: Path,
    output_dir: Path,
    mock_procs: str,
    binding_tsv: Path | None = None,
) -> Path:
    source_tcl = Path(__file__).resolve().parents[1] / "scripts" / "vivado_d4_activity_power.tcl"
    source = source_tcl.read_text(encoding="utf-8")
    start = source.find("proc d4_saif_atom")
    stop = source.find("open_checkpoint $checkpoint")
    assert 0 <= start < stop, "Vivado Tcl helper boundary not found"
    helper_file = tmp_path / "activity_helper_procs.tcl"
    helper_file.write_text(source[start:stop], encoding="utf-8")
    harness = tmp_path / "exercise_activity_helper.tcl"
    binding_arg = f" {{{binding_tsv.as_posix()}}}" if binding_tsv is not None else ""
    harness.write_text(
        f"""source {{{helper_file.as_posix()}}}
{mock_procs}
set alias [d4_prepare_fd_q_alias_saif {{{source_saif.as_posix()}}} {{{output_dir.as_posix()}}} d4_fullnet_impl_top{binding_arg}]
if {{![file isfile $alias]}} {{ error "generated alias SAIF is missing: $alias" }}
puts ACTIVITY_HELPER_PASS
""",
        encoding="utf-8",
    )
    return harness


def d4_binding_table_path() -> Path:
    return (
        Path(__file__).resolve().parents[1]
        / "tests"
        / "fixtures"
        / "d4_activity_binding"
        / "fd_q_hierarchy_bindings.tsv"
    )


def test_binding_fixture_matches_recorded_l2_hierarchy_and_core_provenance():
    root = Path(__file__).resolve().parents[1]
    fixture_root = root / "tests" / "fixtures" / "d4_activity_binding"
    binding_rows = list(
        csv.DictReader(d4_binding_table_path().open(encoding="ascii"), delimiter="\t")
    )
    with (fixture_root / "observed_l2_hierarchy.tsv").open(encoding="ascii", newline="") as stream:
        observed_rows = list(csv.DictReader(stream, delimiter="\t"))
    observed = {
        row["NAME"]: (row["ORIG_REF_NAME"], row["PARENT"])
        for row in observed_rows
        if row["ORIG_REF_NAME"] == "d4_rq_partial_multiplier_lane"
    }
    assert len(binding_rows) == 16
    assert len(observed) == 16
    for lane, row in enumerate(binding_rows):
        assert row["source_scope"] == f"u_core/rq_mul_lanes[{lane}]/rq_mul"
        assert row["physical_scope"] == f"u_core/rq_mul_lanes[{lane}].rq_mul"
        assert observed[row["physical_scope"]] == (
            "d4_rq_partial_multiplier_lane",
            "u_core",
        )

    provenance = json.loads((fixture_root / "source_provenance.json").read_text(encoding="utf-8"))
    assert provenance["frozen_core_path"] == "rtl/cnn/d4_fullnet_top.sv"
    assert provenance["frozen_core_sha256"] == "706cf563ca1f838a337fda154341f1af33c6fdef79a071320ac3259d2f21d529"
    assert provenance["observed_hierarchy_sha256"] == "510b1c68b77c7812d47637fa2f13b96c74a927747dedb26a12484c663d3a83d8"
    assert provenance["source_manifest_sha256"] == "61d0d2b776fc62b6f3185ea9f023cb9427a3f761072ac7cb84794e42b48d91e7"


def binding_mock_procs(
    alias_cells: dict[str, tuple[str, str]],
    *,
    mismatched_ref_lane: int | None = None,
    mismatched_parent_lane: int | None = None,
    missing_native_lane: int | None = None,
    duplicate_native_lane: int | None = None,
) -> str:
    native_cells = [f"rq_cell_{lane}" for lane in range(16) if lane != missing_native_lane]
    if duplicate_native_lane is not None:
        native_cells.append(f"rq_cell_{duplicate_native_lane}")
    lane_cells = " ".join(native_cells)
    alias_names = " ".join(alias_cells)
    name_cases = []
    ref_cases = []
    parent_cases = []
    for lane in range(16):
        physical_scope = f"u_core/rq_mul_lanes[{lane}].rq_mul"
        name_cases.append(f"rq_cell_{lane} {{ return {{{physical_scope}}} }}")
        ref = "unexpected_lane_module" if lane == mismatched_ref_lane else "d4_rq_partial_multiplier_lane"
        parent = "unexpected_parent" if lane == mismatched_parent_lane else "u_core"
        ref_cases.append(f"rq_cell_{lane} {{ return {ref} }}")
        parent_cases.append(f"rq_cell_{lane} {{ return {parent} }}")
    net_cases = []
    for index, (cell, (physical_name, physical_net)) in enumerate(alias_cells.items()):
        net_handle = f"net_alias_{index}"
        name_cases.append(f"{cell} {{ return {{{physical_name}}} }}")
        name_cases.append(f"{net_handle} {{ return {{{physical_net}}} }}")
        net_cases.append(f"q_{cell} {{ return {net_handle} }}")
    return f"""proc get_cells {{args}} {{
    set query [join $args " "]
    if {{[string first {{ORIG_REF_NAME == d4_rq_partial_multiplier_lane}} $query] >= 0}} {{ return {{{lane_cells}}} }}
    if {{[string first {{REF_NAME =~ FD*}} $query] >= 0}} {{ return {{{alias_names}}} }}
    return {{}}
}}
proc get_property {{property object}} {{
    switch -- $property {{
        NAME {{ switch -- $object {{ {' '.join(name_cases)} default {{ error "unknown NAME object: $object" }} }} }}
        ORIG_REF_NAME {{ switch -- $object {{ {' '.join(ref_cases)} default {{ error "unknown ORIG_REF_NAME object: $object" }} }} }}
        PARENT {{ switch -- $object {{ {' '.join(parent_cases)} default {{ error "unknown PARENT object: $object" }} }} }}
    }}
    error "unexpected property lookup: $property $object"
}}
proc get_pins {{args}} {{ return "q_[lindex $args 2]" }}
proc get_nets {{args}} {{ switch -- [lindex $args 2] {{ {' '.join(net_cases)} default {{ error "unknown Q pin: [lindex $args 2]" }} }} }}
proc get_ports {{args}} {{ return {{}} }}
proc get_clocks {{args}} {{ return {{}} }}
proc set_switching_activity {{args}} {{ error "no top-level ports expected in this fixture" }}
"""


def saif_tree(text: str):
    """Read S-expressions independently to check native SAIF clause nesting."""
    stack, result = [], None
    for token in re.findall(r'"(?:\\.|[^"\\])*"|[()]|[^\s()]+', text):
        if token == '(':
            node = []
            if stack:
                stack[-1].append(node)
            else:
                assert result is None
                result = node
            stack.append(node)
        elif token == ')':
            assert stack
            stack.pop()
        else:
            assert stack
            stack[-1].append(json.loads(token) if token.startswith('"') else token)
    assert not stack
    return result


def test_saif_preserves_exact_residency_toggles_aliases_and_hierarchy(tmp_path):
    vcd = write_vcd(
        tmp_path / "tiny.vcd",
        """$version tiny $end
$timescale 10 ps $end
$scope module TOP $end
 $scope module tb $end
  $scope module dut $end
   $var wire 1 ! clk $end
   $var wire 1 ! clk_alias $end
   $var wire 4 \" bus [3:0] $end
   $var wire 1 # unknown_state $end
   $var wire 1 ^ \\odd.name $end
   $scope module child $end
    $var wire 1 $ leaf $end
   $upscope $end
  $upscope $end
 $upscope $end
$upscope $end
$enddefinitions $end
#0
$dumpvars
0!
bxx10 \"
x#
0^
0$
$end
#4
1$
#5
1!
b101z \"
0#
#6
1^
#8
0^
#9
0!
b1101 \"
#12
""",
    )
    saif = tmp_path / "tiny.saif"
    metadata = convert_vcd_to_saif(
        vcd,
        saif,
        ("TOP", "tb", "dut"),
        ("d4_fullnet_impl_top", "u_core"),
    )
    text = saif.read_text(encoding="ascii")

    assert "(TIMESCALE 10 ps)" in text
    assert "(DURATION 12)" in text
    assert "(INSTANCE d4_fullnet_impl_top" in text
    assert "(INSTANCE u_core" in text
    assert '(clk (T0 8) (T1 4) (TX 0) (TZ 0) (TC 2))' in text
    assert '(clk_alias (T0 8) (T1 4) (TX 0) (TZ 0) (TC 2))' in text
    assert '(bus[3] (T0 0) (T1 7) (TX 5) (TZ 0) (TC 0))' in text
    assert '(bus[2] (T0 4) (T1 3) (TX 5) (TZ 0) (TC 1))' in text
    assert '(bus[1] (T0 3) (T1 9) (TX 0) (TZ 0) (TC 1))' in text
    assert '(bus[0] (T0 5) (T1 3) (TX 0) (TZ 4) (TC 0))' in text
    assert '(unknown_state (T0 7) (T1 0) (TX 5) (TZ 0) (TC 0))' in text
    assert '("odd.name" (T0 10) (T1 2) (TX 0) (TZ 0) (TC 2))' in text
    assert '(INSTANCE child' in text
    assert '(leaf (T0 4) (T1 8) (TX 0) (TZ 0) (TC 1))' in text
    assert metadata["duration_value"] == 120
    assert metadata["duration_unit"] == "ps"
    assert metadata["saif_port_entries"] == 1
    assert metadata["saif_net_entries"] == 8
    assert metadata["activity_summary"]["tracked_unique_id_codes"] == 5
    assert metadata["activity_summary"]["aliased_variable_declarations"] == 1
    assert metadata["activity_summary"]["known_toggle_count"] == 7


def test_cli_maps_packed_physical_top_to_single_target_level(tmp_path):
    vcd = write_vcd(
        tmp_path / "packed_top.vcd",
        """$timescale 1 ps $end
$scope module TOP $end
$scope module tb_d4_fullnet_packed $end
$scope module dut $end
$var wire 1 ! clk $end
$var wire 1 \" packed_data $end
$scope module u_core $end
$var wire 1 # core_signal $end
$upscope $end
$upscope $end
$upscope $end
$upscope $end
$enddefinitions $end
#0
$dumpvars
0!
0\"
0#
$end
#3
1!
1\"
1#
""",
    )
    saif = tmp_path / "packed_top.saif"
    metadata = tmp_path / "packed_top.json"

    result = main(
        [
            "--vcd",
            str(vcd),
            "--saif",
            str(saif),
            "--metadata",
            str(metadata),
            "--vcd-root",
            "TOP.tb_d4_fullnet_packed.dut",
            "--target-root",
            "d4_fullnet_impl_top",
        ]
    )

    text = saif.read_text(encoding="ascii")
    assert result == 0
    assert '(DESIGN "d4_fullnet_impl_top")' in text
    assert '(INSTANCE d4_fullnet_impl_top' in text
    assert '(PORT\n' in text
    assert '(NET\n' in text
    assert '(packed_data ' in text
    assert '(INSTANCE u_core' in text
    tree = saif_tree(text)
    top = next(x for x in tree if isinstance(x, list) and x[0] == 'INSTANCE')
    for kind in ('PORT', 'NET'):
        clause = next(x for x in top if isinstance(x, list) and x[0] == kind)
        assert all(isinstance(entry, list) and len(entry) == 6 for entry in clause[1:])
        assert all({field[0] for field in entry[1:]} == {'T0', 'T1', 'TX', 'TZ', 'TC'} for entry in clause[1:])
    assert '(core_signal ' in text
    assert json.loads(metadata.read_text(encoding="utf-8"))["target_scope_prefix"] == [
        "d4_fullnet_impl_top"
    ]


def test_converter_preserves_indexed_generated_sibling_hierarchy(tmp_path):
    vcd = write_vcd(
        tmp_path / "indexed_lanes.vcd",
        """$timescale 1 ps $end
$scope module TOP $end
$scope module tb $end
$scope module dut $end
$scope module rq_mul_lanes[0] $end
$scope module rq_mul $end
$var wire 1 ! mul_q[0] $end
$upscope $end
$upscope $end
$scope module rq_mul_lanes[15] $end
$scope module rq_mul $end
$var wire 1 \" mul_q[15] $end
$upscope $end
$upscope $end
$upscope $end
$upscope $end
$upscope $end
$enddefinitions $end
#0
0!
1\"
#2
0\"
#4
1!
#8
""",
    )
    saif = tmp_path / "indexed_lanes.saif"
    metadata = convert_vcd_to_saif(
        vcd,
        saif,
        ("TOP", "tb", "dut"),
        ("d4_fullnet_impl_top", "u_core"),
    )
    text = saif.read_text(encoding="ascii")
    tree = saif_tree(text)
    top = next(node for node in tree if isinstance(node, list) and node[0] == "INSTANCE")
    core = next(node for node in top if isinstance(node, list) and node[0] == "INSTANCE")
    lanes = {
        node[1]: node
        for node in core
        if isinstance(node, list) and node[0] == "INSTANCE"
    }
    assert set(lanes) == {"rq_mul_lanes[0]", "rq_mul_lanes[15]"}
    for index, expected in ((0, [4, 4, 0, 0, 1]), (15, [6, 2, 0, 0, 1])):
        lane_children = [
            node for node in lanes[f"rq_mul_lanes[{index}]"]
            if isinstance(node, list) and node[0] == "INSTANCE"
        ]
        assert len(lane_children) == 1 and lane_children[0][1] == "rq_mul"
        net_clause = next(
            node for node in lane_children[0]
            if isinstance(node, list) and node[0] == "NET"
        )
        signal = next(entry for entry in net_clause[1:] if entry[0] == f"mul_q[{index}]")
        assert {field[0]: int(field[1]) for field in signal[1:]} == dict(
            zip(("T0", "T1", "TX", "TZ", "TC"), expected)
        )
    assert metadata["saif_net_entries"] == 2
    assert metadata["target_scope_prefix"] == ["d4_fullnet_impl_top", "u_core"]


def test_duration_override_accounts_for_final_hold_time(tmp_path):
    vcd = write_vcd(
        tmp_path / "short.vcd",
        """$timescale 1 ns $end
$scope module TOP $end
$scope module tb $end
$scope module dut $end
$var wire 1 ! sig $end
$upscope $end
$upscope $end
$upscope $end
$enddefinitions $end
#0
1!
#4
0!
""",
    )
    parsed = parse_vcd(vcd, ("TOP", "tb", "dut"), duration_ticks=10)
    counts = parsed.activity_by_code["!"].counts[0]
    assert parsed.final_tick == 10
    assert counts == [6, 4, 0, 0, 1]


@pytest.mark.parametrize(
    "body, expected",
    [
        (
            "$timescale 1 ps $end\n$scope module TOP $end\n$scope module tb $end\n"
            "$scope module dut $end\n$var real 64 ! val $end\n$upscope $end\n"
            "$upscope $end\n$upscope $end\n$enddefinitions $end\n#1\n",
            "unsupported VCD variable kind",
        ),
        (
            "$timescale 1 ps $end\n$scope module TOP $end\n$scope module tb $end\n"
            "$scope module dut $end\n$var wire 1 ! sig $end\n$upscope $end\n"
            "$upscope $end\n$upscope $end\n$enddefinitions $end\n#1\nr1.5 !\n",
            "unsupported VCD real value",
        ),
    ],
)
def test_unsupported_real_inputs_fail_with_clear_diagnostics(tmp_path, body, expected):
    vcd = write_vcd(tmp_path / "bad.vcd", body)
    with pytest.raises(VcdError, match=expected):
        parse_vcd(vcd, ("TOP", "tb", "dut"))


def test_scope_mismatch_and_zero_duration_fail(tmp_path):
    vcd = write_vcd(
        tmp_path / "scope.vcd",
        """$timescale 1 ps $end
$scope module TOP $end
$scope module dut $end
$var wire 1 ! sig $end
$upscope $end
$upscope $end
$enddefinitions $end
#0
0!
""",
    )
    with pytest.raises(VcdError, match="no variables under requested source scope"):
        parse_vcd(vcd, ("TOP", "tb", "dut"))


def test_vivado_tcl_fd_q_alias_preserves_stats_and_excludes_conflicts(tmp_path):
    tclsh = shutil.which("tclsh")
    if not tclsh:
        pytest.skip("tclsh is required to exercise the Vivado Tcl helper")

    checkpoint = tmp_path / "input.dcp"
    source_saif = tmp_path / "source.saif"
    output_dir = tmp_path / "out"
    checkpoint.touch()
    output_dir.mkdir()
    source_saif.write_text(
        """(SAIFILE
(TIMESCALE 2 ps)
(DURATION 5000)
(INSTANCE d4_fullnet_impl_top
 (PORT (clk (T0 2500) (T1 2500) (TX 0) (TZ 0) (TC 5000)))
 (PORT
  (data_in (T0 3000) (T1 2000) (TX 0) (TZ 0) (TC 3))
  (bus[3] (T0 2500) (T1 2500) (TX 0) (TZ 0) (TC 16))
  (bus[2] (T0 4500) (T1 400) (TX 100) (TZ 0) (TC 2))
  (out_valid (T0 5000) (T1 0) (TX 0) (TZ 0) (TC 0))
  (io_pin (T0 2500) (T1 2500) (TX 0) (TZ 0) (TC 2))
  (unmatched (T0 5000) (T1 0) (TX 0) (TZ 0) (TC 0))
 )
 (NET packed_sig (T0 5000) (T1 0) (TX 0) (TZ 0) (TC 0))
 (INSTANCE u_core
  (NET dupe_a (T0 4000) (T1 1000) (TX 0) (TZ 0) (TC 1))
  (NET
   (dupe_b (T0 3500) (T1 1500) (TX 0) (TZ 0) (TC 2))
   (baz[1] (T0 1500) (T1 1000) (TX 500) (TZ 2000) (TC 7))
   (state[1] (T0 5000) (T1 0) (TX 0) (TZ 0) (TC 0))
  )
 )
)
""",
        encoding="ascii",
    )

    source_tcl = Path(__file__).resolve().parents[1] / "scripts" / "vivado_d4_activity_power.tcl"
    harness = tmp_path / "exercise_alias.tcl"
    harness.write_text(
        f"""set argv [list {{{checkpoint.as_posix()}}} {{{source_saif.as_posix()}}} {{{output_dir.as_posix()}}} {{d4_fullnet_impl_top.u_core}}]
proc get_cells {{args}} {{ return {{cell_dupe_a cell_dupe_b cell_baz cell_state}} }}
proc get_property {{property object}} {{
    if {{$property eq "DIRECTION"}} {{
        switch -- $object {{
            pclk {{ return IN }}
            pdata {{ return IN }}
            pbus3 {{ return IN }}
            pbus2 {{ return IN }}
            pout {{ return OUT }}
            pio {{ return INOUT }}
            default {{ error "unexpected DIRECTION lookup: $object" }}
        }}
    }}
    if {{$property eq "NAME"}} {{
        switch -- $object {{
            cell_dupe_a {{ return u_core/dupe_a_reg }}
            cell_dupe_b {{ return u_core/dupe_b_reg }}
            cell_baz {{ return {{u_core/baz_reg[1]}} }}
            cell_state {{ return {{u_core/state_reg[1]}} }}
            pclk {{ return clk }}
            pdata {{ return data_in }}
            pbus3 {{ return {{bus[3]}} }}
            pbus2 {{ return {{bus[2]}} }}
            pout {{ return out_valid }}
            pio {{ return io_pin }}
            n_shared {{ return d4_fullnet_impl_top/u_core/shared_net }}
            n_baz {{ return {{d4_fullnet_impl_top/u_core/baz.net[1]}} }}
            default {{ error "unexpected NAME lookup: $object" }}
        }}
    }}
    error "unexpected property lookup: $property $object"
}}
proc get_pins {{args}} {{ return q_[lindex $args 2] }}
proc get_nets {{args}} {{
    set pin [lindex $args 2]
    if {{$pin in {{q_cell_dupe_a q_cell_dupe_b}}}} {{ return n_shared }}
    if {{$pin eq "q_cell_baz"}} {{ return n_baz }}
    error "unexpected net lookup: $pin"
}}
proc get_ports {{args}} {{ return {{pclk pdata pbus3 pbus2 pout pio}} }}
proc get_clocks {{args}} {{ if {{[lindex $args end] eq "pclk"}} {{ return clk_obj }}; return {{}} }}
set ::set_switching_activity_calls {{}}
proc set_switching_activity {{args}} {{ lappend ::set_switching_activity_calls $args }}
set f [open {{{source_tcl.as_posix()}}} r]
set source [read $f]
close $f
set start [string first "proc d4_saif_atom" $source]
set marker {{open_checkpoint $checkpoint}}
set stop [string first $marker $source]
if {{$start < 0 || $stop < 0 || $start >= $stop}} {{ error "Vivado Tcl helper boundary not found" }}
set prefix [string range $source $start [expr {{$stop - 1}}]]
eval $prefix
set alias [d4_prepare_fd_q_alias_saif {{{source_saif.as_posix()}}} {{{output_dir.as_posix()}}} d4_fullnet_impl_top]
if {{![file isfile $alias]}} {{ error "generated alias SAIF is missing: $alias" }}
if {{[llength $::set_switching_activity_calls] != 2}} {{ error "expected two exact known nonclock input assignments, got [llength $::set_switching_activity_calls]" }}
foreach call $::set_switching_activity_calls {{ puts "SET_CALL=[join $call |]" }}
puts ALIAS_HARNESS_PASS
""",
        encoding="utf-8",
    )
    result = subprocess.run(
        [tclsh, str(harness)], capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "ALIAS_HARNESS_PASS" in result.stdout
    calls = [line.removeprefix("SET_CALL=").split("|") for line in result.stdout.splitlines() if line.startswith("SET_CALL=")]
    by_port = {call[-1]: call for call in calls}
    assert set(by_port) == {"pdata", "pbus3"}
    assert by_port["pdata"][:1] == ["-signal_rate"]
    assert math.isclose(float(by_port["pdata"][1]), 300.0)
    assert by_port["pdata"][2] == "-static_probability"
    assert math.isclose(float(by_port["pdata"][3]), 0.4)
    assert by_port["pbus3"][:1] == ["-signal_rate"]
    assert math.isclose(float(by_port["pbus3"][1]), 1600.0)
    assert by_port["pbus3"][2] == "-static_probability"
    assert math.isclose(float(by_port["pbus3"][3]), 0.5)

    alias_saif = (output_dir / "fd_q_alias.saif").read_text(encoding="utf-8")
    points = (output_dir / "fd_q_alias_points.tsv").read_text(encoding="utf-8")
    summary = (output_dir / "fd_q_alias_summary.txt").read_text(encoding="utf-8")
    assert '(baz\\.net[1] (T0 1500) (T1 1000) (TX 500) (TZ 2000) (TC 7))' in alias_saif
    assert "state_reg" not in alias_saif
    assert "baz[1]\td4_fullnet_impl_top/u_core/baz.net[1]\t1500\t1000\t500\t2000\t7" in points
    assert "shared_net" not in alias_saif
    assert "exact_FD_Q_physical_name_alias_records=1" in summary
    assert "conflicting_FD_Q_aliases_excluded=1" in summary
    assert "records_with_unknown_statistics_preserved_in_source_saif=2" in summary
    assert "source_top_level_port_records=7" in summary
    assert "exact_design_port_name_candidates=6" in summary
    assert "top_level_nonclock_ports_annotated_by_original_read_saif" not in summary
    assert "top_level_nonclock_input_candidates=3" in summary
    assert "explicit_set_switching_activity_assignments=2" in summary
    assert "clock_ports_excluded=1" in summary
    assert "non_input_ports_excluded=2" in summary
    assert "unknown_activity_input_ports_skipped=1" in summary

    port_rows = {
        row["port_name"]: row
        for row in csv.DictReader(
            (output_dir / "top_level_port_activity_assignments.tsv").open(encoding="utf-8"),
            delimiter="\t",
        )
    }
    assert math.isclose(float(port_rows["data_in"]["duration_seconds"]), 10e-9)
    assert port_rows["data_in"]["T0"] == "3000"
    assert port_rows["data_in"]["T1"] == "2000"
    assert port_rows["data_in"]["TX"] == "0"
    assert port_rows["data_in"]["TZ"] == "0"
    assert port_rows["data_in"]["TC"] == "3"
    assert float(port_rows["data_in"]["static_probability"]) == 0.4
    assert float(port_rows["data_in"]["signal_rate_mtransitions_per_s"]) == 300.0
    assert float(port_rows["bus[3]"]["signal_rate_mtransitions_per_s"]) == 1600.0
    assert port_rows["bus[2]"]["set_switching_activity"] == "0"
    assert port_rows["bus[2]"]["TX"] == "100"
    assert port_rows["bus[2]"]["reason"] == "unknown_state_residency_skipped"
    assert port_rows["clk"]["reason"] == "clock_port_excluded"
    assert port_rows["out_valid"]["reason"] == "non_input_port_excluded"
    assert port_rows["io_pin"]["reason"] == "non_input_port_excluded"
    assert port_rows["unmatched"]["reason"] == "no_exact_design_port_name"
    tree = saif_tree(alias_saif)
    top = next(node for node in tree if isinstance(node, list) and node[0] == "INSTANCE")
    core = next(node for node in top if isinstance(node, list) and node[0] == "INSTANCE")
    net_clause = next(node for node in core if isinstance(node, list) and node[0] == "NET")
    assert net_clause[1][0] == "baz\\.net[1]"
    assert {field[0] for field in net_clause[1][1:]} == {"T0", "T1", "TX", "TZ", "TC"}


def test_vivado_tcl_fd_q_alias_preserves_indexed_siblings_and_conflicts(tmp_path):
    tclsh = shutil.which("tclsh")
    if not tclsh:
        pytest.skip("tclsh is required to exercise the Vivado Tcl helper")

    source_saif = tmp_path / "indexed_source.saif"
    output_dir = tmp_path / "out"
    output_dir.mkdir()
    source_saif.write_text(
        """(SAIFILE
(TIMESCALE 1 ps)
(DURATION 10)
(INSTANCE d4_fullnet_impl_top
 (INSTANCE u_core
  (INSTANCE rq_mul_lanes[0]
   (INSTANCE rq_mul
    (NET
     (mul_q[0] (T0 4) (T1 6) (TX 0) (TZ 0) (TC 3))
     (conflict_q (T0 8) (T1 2) (TX 0) (TZ 0) (TC 1))
    )
   )
  )
  (INSTANCE rq_mul_lanes[15]
   (INSTANCE rq_mul
    (NET
     (mul_q[15] (T0 2) (T1 8) (TX 0) (TZ 0) (TC 5))
     (conflict_q (T0 7) (T1 3) (TX 0) (TZ 0) (TC 2))
    )
   )
  )
 )
)
)
""",
        encoding="ascii",
    )
    mock_procs = r"""proc get_cells {args} { return {cell_q0 cell_q15 cell_conflict0 cell_conflict15} }
proc get_property {property object} {
    if {$property eq "NAME"} {
        switch -- $object {
            cell_q0 { return {u_core/rq_mul_lanes[0]/rq_mul/mul_q_reg[0]} }
            cell_q15 { return {u_core/rq_mul_lanes[15]/rq_mul/mul_q_reg[15]} }
            cell_conflict0 { return {u_core/rq_mul_lanes[0]/rq_mul/conflict_q_reg} }
            cell_conflict15 { return {u_core/rq_mul_lanes[15]/rq_mul/conflict_q_reg} }
            net_q0 { return {d4_fullnet_impl_top/u_core/rq_mul_lanes[0].rq_mul/mul_q_net[0]} }
            net_q15 { return {d4_fullnet_impl_top/u_core/rq_mul_lanes[15].rq_mul/mul_q_net[15]} }
            net_shared { return {d4_fullnet_impl_top/u_core/shared_net} }
        }
    }
    error "unexpected property lookup: $property $object"
}
proc get_pins {args} { return "q_[lindex $args 2]" }
proc get_nets {args} {
    switch -- [lindex $args 2] {
        q_cell_q0 { return net_q0 }
        q_cell_q15 { return net_q15 }
        q_cell_conflict0 - q_cell_conflict15 { return net_shared }
    }
    error "unexpected pin lookup: [lindex $args 2]"
}
proc get_ports {args} { return {} }
proc get_clocks {args} { return {} }
proc set_switching_activity {args} { error "no top-level ports expected in this fixture" }
"""
    harness = write_tcl_alias_harness(tmp_path, source_saif, output_dir, mock_procs)
    result = subprocess.run([tclsh, str(harness)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "ACTIVITY_HELPER_PASS" in result.stdout

    alias_saif = (output_dir / "fd_q_alias.saif").read_text(encoding="ascii")
    points = (output_dir / "fd_q_alias_points.tsv").read_text(encoding="ascii")
    summary = (output_dir / "fd_q_alias_summary.txt").read_text(encoding="ascii")
    assert '(mul_q_net[0] (T0 4) (T1 6) (TX 0) (TZ 0) (TC 3))' in alias_saif
    assert '(mul_q_net[15] (T0 2) (T1 8) (TX 0) (TZ 0) (TC 5))' in alias_saif
    assert "rq_mul_lanes\\[0\\]\\.rq_mul" in alias_saif
    assert "rq_mul_lanes\\[15\\]\\.rq_mul" in alias_saif
    assert "rq_mul_lanes[0]\n" not in alias_saif
    assert "u_core/rq_mul_lanes[0]/rq_mul/mul_q[0]\td4_fullnet_impl_top/u_core/rq_mul_lanes[0].rq_mul/mul_q_net[0]\t4\t6\t0\t0\t3" in points
    assert "u_core/rq_mul_lanes[15]/rq_mul/mul_q[15]\td4_fullnet_impl_top/u_core/rq_mul_lanes[15].rq_mul/mul_q_net[15]\t2\t8\t0\t0\t5" in points
    assert "exact_FD_Q_physical_name_alias_records=2" in summary
    assert "conflicting_FD_Q_aliases_excluded=1" in summary
    assert "NET_records_without_exact_FD_Q_alias=0" in summary
    assert "explicit_hierarchy_binding=enabled" not in summary
    assert not (output_dir / "fd_q_hierarchy_binding_validation.tsv").exists()


@pytest.mark.parametrize(
    "instance_line",
    ["(INSTANCE rq_mul_lanes[x]", "(INSTANCE rq_mul_lanes[0", "(INSTANCE rq_mul_lanes[0][x]"],
)
def test_vivado_tcl_rejects_malformed_indexed_instance_records(tmp_path, instance_line):
    tclsh = shutil.which("tclsh")
    if not tclsh:
        pytest.skip("tclsh is required to exercise the Vivado Tcl helper")

    source_saif = tmp_path / "malformed_instance.saif"
    output_dir = tmp_path / "out"
    output_dir.mkdir()
    source_saif.write_text(
        f"""(SAIFILE
(TIMESCALE 1 ps)
(DURATION 10)
(INSTANCE d4_fullnet_impl_top
 (INSTANCE u_core
  {instance_line}
   (NET
    (mul_q (T0 10) (T1 0) (TX 0) (TZ 0) (TC 0))
   )
  )
 )
)
)
""",
        encoding="ascii",
    )
    mock_procs = """proc get_cells {args} { return {} }
proc get_property {property object} { error "unexpected property lookup" }
proc get_pins {args} { error "unexpected pin lookup" }
proc get_nets {args} { error "unexpected net lookup" }
proc get_ports {args} { return {} }
proc get_clocks {args} { return {} }
proc set_switching_activity {args} { error "unexpected activity assignment" }
"""
    harness = write_tcl_alias_harness(tmp_path, source_saif, output_dir, mock_procs)
    result = subprocess.run([tclsh, str(harness)], capture_output=True, text=True, check=False)
    assert result.returncode != 0
    assert "Malformed SAIF INSTANCE record" in result.stdout + result.stderr


@pytest.mark.parametrize(
    "record, expected_error",
    [
        (
            "(data (T0 4) (T1 4) (TX invalid) (TZ 0) (TC 2))",
            "Malformed top-level SAIF PORT record",
        ),
        (
            "(data (T0 8) (T1 1) (TX 0) (TZ 0) (TC 2))",
            "SAIF PORT residency for data does not equal DURATION",
        ),
    ],
)
def test_vivado_tcl_rejects_malformed_top_level_port_activity(
    tmp_path, record, expected_error
):
    tclsh = shutil.which("tclsh")
    if not tclsh:
        pytest.skip("tclsh is required to exercise the Vivado Tcl helper")

    checkpoint = tmp_path / "input.dcp"
    source_saif = tmp_path / "malformed.saif"
    output_dir = tmp_path / "out"
    checkpoint.touch()
    output_dir.mkdir()
    source_saif.write_text(
        f"""(SAIFILE
(TIMESCALE 1 ns)
(DURATION 10)
(INSTANCE d4_fullnet_impl_top
 (PORT
  {record}
 )
)
)\n""",
        encoding="ascii",
    )
    source_tcl = Path(__file__).resolve().parents[1] / "scripts" / "vivado_d4_activity_power.tcl"
    harness = tmp_path / "exercise_malformed_port.tcl"
    harness.write_text(
        f"""set argv [list {{{checkpoint.as_posix()}}} {{{source_saif.as_posix()}}} {{{output_dir.as_posix()}}} {{d4_fullnet_impl_top.u_core}}]
proc get_cells {{args}} {{ return {{}} }}
proc get_ports {{args}} {{ return {{pdata}} }}
proc get_property {{property object}} {{
    if {{$property eq "NAME" && $object eq "pdata"}} {{ return data }}
    if {{$property eq "DIRECTION" && $object eq "pdata"}} {{ return IN }}
    error "unexpected property lookup: $property $object"
}}
proc get_clocks {{args}} {{ return {{}} }}
proc set_switching_activity {{args}} {{ error "malformed input must not be assigned" }}
set f [open {{{source_tcl.as_posix()}}} r]
set source [read $f]
close $f
set start [string first "proc d4_saif_atom" $source]
set marker {{open_checkpoint $checkpoint}}
set stop [string first $marker $source]
set prefix [string range $source $start [expr {{$stop - 1}}]]
eval $prefix
d4_prepare_fd_q_alias_saif {{{source_saif.as_posix()}}} {{{output_dir.as_posix()}}} d4_fullnet_impl_top
""",
        encoding="utf-8",
    )
    result = subprocess.run(
        [tclsh, str(harness)], capture_output=True, text=True, check=False
    )
    assert result.returncode != 0
    assert expected_error in result.stdout + result.stderr


def test_explicit_binding_maps_small_saif_fixture_with_native_property_mocks(tmp_path):
    tclsh = shutil.which("tclsh")
    if not tclsh:
        pytest.skip("tclsh is required to exercise the Vivado Tcl helper")

    source_saif = (
        Path(__file__).resolve().parents[1]
        / "tests"
        / "fixtures"
        / "d4_activity_binding"
        / "binding_smoke.saif"
    )
    output_dir = tmp_path / "out"
    output_dir.mkdir()
    aliases = {
        "cell_q0": (
            "u_core/rq_mul_lanes[0].rq_mul/mul_q_reg[0]",
            "d4_fullnet_impl_top/u_core/rq_mul_lanes[0].rq_mul/mul_q_net[0]",
        ),
        "cell_q15": (
            "u_core/rq_mul_lanes[15].rq_mul/mul_q_reg[15]",
            "d4_fullnet_impl_top/u_core/rq_mul_lanes[15].rq_mul/mul_q_net[15]",
        ),
    }
    harness = write_tcl_alias_harness(
        tmp_path,
        source_saif,
        output_dir,
        binding_mock_procs(aliases),
        d4_binding_table_path(),
    )
    result = subprocess.run([tclsh, str(harness)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "ACTIVITY_HELPER_PASS" in result.stdout

    alias_saif = (output_dir / "fd_q_alias.saif").read_text(encoding="ascii")
    points = (output_dir / "fd_q_alias_points.tsv").read_text(encoding="ascii")
    summary = (output_dir / "fd_q_alias_summary.txt").read_text(encoding="ascii")
    validation = (output_dir / "fd_q_hierarchy_binding_validation.tsv").read_text(encoding="ascii")
    assert '(mul_q_net[0] (T0 4) (T1 4) (TX 0) (TZ 0) (TC 1))' in alias_saif
    assert '(mul_q_net[15] (T0 6) (T1 2) (TX 0) (TZ 0) (TC 1))' in alias_saif
    assert "u_core/rq_mul_lanes[0]/rq_mul/mul_q[0]\td4_fullnet_impl_top/u_core/rq_mul_lanes[0].rq_mul/mul_q_net[0]\t4\t4\t0\t0\t1" in points
    assert "u_core/rq_mul_lanes[15]/rq_mul/mul_q[15]\td4_fullnet_impl_top/u_core/rq_mul_lanes[15].rq_mul/mul_q_net[15]\t6\t2\t0\t0\t1" in points
    assert "explicit_hierarchy_binding=enabled" in summary
    assert "explicit_hierarchy_binding_rows=16" in summary
    assert validation.count("\tPASS\n") == 16


def test_explicit_binding_has_path_boundary_and_leaves_other_scopes_exact(tmp_path):
    tclsh = shutil.which("tclsh")
    if not tclsh:
        pytest.skip("tclsh is required to exercise the Vivado Tcl helper")

    source_saif = tmp_path / "boundary.saif"
    source_saif.write_text(
        """(SAIFILE
(TIMESCALE 1 ps)
(DURATION 10)
(INSTANCE d4_fullnet_impl_top
 (INSTANCE u_core
  (INSTANCE rq_mul_lanes[0]
   (INSTANCE rq_mul_extra
    (NET (boundary_q (T0 4) (T1 6) (TX 0) (TZ 0) (TC 2)))
   )
  )
  (INSTANCE other
   (NET (plain_q (T0 7) (T1 3) (TX 0) (TZ 0) (TC 4)))
  )
 )
)
)
""",
        encoding="ascii",
    )
    output_dir = tmp_path / "out"
    output_dir.mkdir()
    aliases = {
        "cell_boundary": (
            "u_core/rq_mul_lanes[0].rq_mul_extra/boundary_q_reg",
            "d4_fullnet_impl_top/u_core/rq_mul_lanes[0].rq_mul_extra/boundary_q_net",
        ),
        "cell_other": (
            "u_core/other/plain_q_reg",
            "d4_fullnet_impl_top/u_core/other/plain_q_net",
        ),
    }
    harness = write_tcl_alias_harness(
        tmp_path,
        source_saif,
        output_dir,
        binding_mock_procs(aliases),
        d4_binding_table_path(),
    )
    result = subprocess.run([tclsh, str(harness)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout + result.stderr

    alias_saif = (output_dir / "fd_q_alias.saif").read_text(encoding="ascii")
    points = (output_dir / "fd_q_alias_points.tsv").read_text(encoding="ascii")
    summary = (output_dir / "fd_q_alias_summary.txt").read_text(encoding="ascii")
    assert "boundary_q_net" not in alias_saif
    assert '(plain_q_net (T0 7) (T1 3) (TX 0) (TZ 0) (TC 4))' in alias_saif
    assert "u_core/other/plain_q\td4_fullnet_impl_top/u_core/other/plain_q_net\t7\t3\t0\t0\t4" in points
    assert "exact_FD_Q_physical_name_alias_records=1" in summary
    assert "NET_records_without_exact_FD_Q_alias=1" in summary


@pytest.mark.parametrize(
    "case,expected_error",
    [
        ("duplicate", "Duplicate FD-Q source scope"),
        ("overlap", "Overlapping FD-Q source scopes"),
        ("missing", "must contain all 16 enumerated L2 RQ scopes"),
        ("malformed", "expected four TSV fields"),
    ],
)
def test_explicit_binding_rejects_duplicate_overlap_missing_and_malformed_rows(
    tmp_path, case, expected_error
):
    tclsh = shutil.which("tclsh")
    if not tclsh:
        pytest.skip("tclsh is required to exercise the Vivado Tcl helper")

    lines = d4_binding_table_path().read_text(encoding="ascii").splitlines()
    rows = lines[1:]
    if case == "duplicate":
        rows[-1] = rows[0]
    elif case == "overlap":
        rows.append(
            "u_core/rq_mul_lanes[0]\tu_core/overlap\td4_rq_partial_multiplier_lane\tu_core"
        )
    elif case == "missing":
        rows = rows[:-1]
    elif case == "malformed":
        rows[0] = "u_core/rq_mul_lanes[0]/rq_mul\tu_core/rq_mul_lanes[0].rq_mul"
    binding_tsv = tmp_path / f"{case}.tsv"
    binding_tsv.write_text("\n".join([lines[0], *rows]) + "\n", encoding="ascii")
    source_saif = tmp_path / "unused.saif"
    source_saif.write_text("", encoding="ascii")
    output_dir = tmp_path / "out"
    output_dir.mkdir()
    harness = write_tcl_alias_harness(
        tmp_path, source_saif, output_dir, binding_mock_procs({}), binding_tsv
    )
    result = subprocess.run([tclsh, str(harness)], capture_output=True, text=True, check=False)
    assert result.returncode != 0
    assert expected_error in result.stdout + result.stderr


@pytest.mark.parametrize(
    "property_name,expected_error",
    [
        ("missing_cell", "found 0"),
        ("duplicate_cell", "found 2"),
        ("orig_ref", "native property mismatch"),
        ("parent", "native property mismatch"),
    ],
)
def test_explicit_binding_rejects_missing_ambiguous_and_mismatched_native_cells(
    tmp_path, property_name, expected_error
):
    tclsh = shutil.which("tclsh")
    if not tclsh:
        pytest.skip("tclsh is required to exercise the Vivado Tcl helper")

    output_dir = tmp_path / "out"
    output_dir.mkdir()
    source_saif = tmp_path / "unused.saif"
    source_saif.write_text("", encoding="ascii")
    aliases = {}
    mismatch_options = {
        "missing_native_lane": 0 if property_name == "missing_cell" else None,
        "duplicate_native_lane": 0 if property_name == "duplicate_cell" else None,
        "mismatched_ref_lane": 0 if property_name == "orig_ref" else None,
        "mismatched_parent_lane": 0 if property_name == "parent" else None,
    }
    harness = write_tcl_alias_harness(
        tmp_path,
        source_saif,
        output_dir,
        binding_mock_procs(aliases, **mismatch_options),
        d4_binding_table_path(),
    )
    result = subprocess.run([tclsh, str(harness)], capture_output=True, text=True, check=False)
    assert result.returncode != 0
    assert expected_error in result.stdout + result.stderr
    validation = (output_dir / "fd_q_hierarchy_binding_validation.tsv").read_text(encoding="ascii")
    if property_name in {"orig_ref", "parent"}:
        assert "REJECTED_NATIVE_PROPERTY_MISMATCH" in validation
    else:
        assert "REJECTED_NAME_MATCH_COUNT" in validation
