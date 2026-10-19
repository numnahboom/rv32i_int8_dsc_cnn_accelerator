# Exact RQ lane comparison only; reported area excludes the rest of D4/memories.
set style $env(D4_RQ_STYLE)
if {$style ni {partial native}} {error "Unexpected RQ style"}
set corner tt
if {[info exists env(D4_ASIC_CORNER)]} {set corner $env(D4_ASIC_CORNER)}
set period 8.0
if {[info exists env(D4_ASIC_PERIOD_NS)]} {set period $env(D4_ASIC_PERIOD_NS)}
set out build/reports/asic_rq_${style}_${corner}_20261019
file mkdir $out
set libroot /opt/pdk/smic0.18um/DigitalIC
if {$corner eq "tt"} {
    set db $libroot/6_SCC018UG_HD_RVT_lib_tt_v1p8_V0.3a/liberty/1.8v/scc018ug_hd_rvt_tt_v1p8_25c_basic.db
} elseif {$corner eq "ss"} {
    set db $libroot/5_SCC018UG_HD_RVT_lib_ss_v1p62_V0.3a/liberty/1.8v/scc018ug_hd_rvt_ss_v1p62_125c_basic.db
} else {error "Uncharacterized corner"}
set_app_var target_library [list $db]
set_app_var link_library [concat * $target_library]
set_host_options -max_cores 4
if {$style eq "partial"} {
    analyze -format sverilog build/asic_eval/partial/d4_fullnet_eval.sv
    set top d4_rq_partial_multiplier_lane
} else {
    analyze -format sverilog rtl/asic/d4_rq_native_multiplier_lane.sv
    set top d4_rq_native_multiplier_lane
}
elaborate $top
current_design $top
if {![link]} {error "Unresolved design"}
create_clock -name clk -period $period [get_ports clk]
set_clock_uncertainty 0.2 [get_clocks clk]
set_input_delay -max 0.5 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay -min 0.1 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay -max 0.5 -clock clk [all_outputs]
set_output_delay -min 0.1 -clock clk [all_outputs]
set_input_transition 0.1 [remove_from_collection [all_inputs] [get_ports clk]]
# Standard library units are recorded below; 0.01 pF output load.
set_load 0.01 [all_outputs]
compile_ultra
redirect $out/units.rpt {report_units}
redirect $out/area.rpt {report_area -hierarchy}
redirect $out/qor.rpt {report_qor}
redirect $out/timing_max.rpt {report_timing -max_paths 10 -delay_type max}
redirect $out/timing_min.rpt {report_timing -max_paths 10 -delay_type min}
redirect $out/constraints.rpt {report_constraint -all_violators}
redirect $out/check.rpt {check_design}
redirect $out/power_vectorless.rpt {report_power}
write -format ddc -hierarchy -output $out/mapped.ddc
write -format verilog -hierarchy -output $out/mapped.v
write_sdc $out/constraints.sdc
set f [open $out/area.rpt r]
set area_report [read $f]
close $f
if {![regexp {Total cell area:\s+([0-9.eE+-]+)} $area_report -> area]} {
    error "Missing mapped cell area; refuse an incomplete result"
}
set path [get_timing_paths -delay_type max -max_paths 1]
set slack [get_attribute $path slack]
if {![string is double -strict $slack]} {error "Missing setup slack"}
set f [open $out/result.json w]
puts $f "{\"style\":\"$style\",\"corner\":\"$corner\",\"period_ns\":$period,\"cell_area_um2\":$area,\"worst_setup_slack_ns\":$slack,\"scope\":\"isolated_RQ_lane_synthesis_only\",\"power_claim\":false}"
close $f
puts "D4_ASIC_RQ_SYNTH_COMPLETE style=$style corner=$corner area_um2=$area slack_ns=$slack"
quit
