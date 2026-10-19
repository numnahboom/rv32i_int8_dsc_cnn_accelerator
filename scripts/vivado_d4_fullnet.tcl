set out [file normalize [lindex $argv 0]]
set mode [lindex $argv 1]
proc d4_report_endpoint_groups {out stage} {
    foreach {label pattern} {
        rq_product *rq_product_reg*
        rq_lane_operand *rq_mul*/*_common_reg*
        rq_lane_partial *rq_mul*/p??_q_reg*
        rq_lane_merge *rq_mul*/cross_q_reg*
        rq_lane_product *rq_mul*/product_reg*
        rq_round *rq_value_reg*
        rq_clamp *result_vector_reg*
        state *state_reg*
    } {
        set endpoints [get_cells -hier -quiet -filter "NAME =~ $pattern"]
        set report [file join $out "${label}_${stage}_paths.txt"]
        if {[llength $endpoints]} {
            report_timing -delay_type max -max_paths 3 -to $endpoints -file $report
        } else {
            set missing [open $report w]
            puts $missing "No cells matched $pattern; no stage timing claim."
            close $missing
        }
    }
    report_timing -delay_type max -max_paths 5 -from [all_inputs] \
        -to [all_registers] -file [file join $out "inputs_${stage}_paths.txt"]
    report_timing -delay_type max -max_paths 5 -to [all_outputs] \
        -file [file join $out "outputs_${stage}_paths.txt"]
}
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set_param general.maxThreads 8
create_project -in_memory -part xc7z020clg400-1
set_property verilog_define {D4_USE_XILINX_CLOCKING} [current_fileset]
read_verilog -sv [list rtl/cnn/d4_fullnet_clocking.sv rtl/cnn/d4_fullnet_top.sv rtl/cnn/d4_fullnet_impl_top.sv]
read_xdc constraints/d4_fullnet_8ns.xdc
synth_design -top d4_fullnet_impl_top -part xc7z020clg400-1
# Reapply uncertainty after MMCM clocks exist in the synthesized timing graph.
set_clock_uncertainty 0.200 [get_clocks -include_generated_clocks]
# The status outputs are combinationally masked by clock operational state.
# Their inherited core IOB attributes cannot place those flops at the pads.
foreach cell [get_cells -hier -filter {IOB == TRUE}] {
    set name [get_property NAME $cell]
    if {[regexp {u_core.*(start_ready|input_ready|done_valid|logit_valid|busy)} $name]} {
        set_property IOB FALSE $cell
    }
}
report_clocks -file $out/clocks_synth.txt
set hierarchyfh [open $out/hierarchy_synth.tsv w]
puts $hierarchyfh "NAME\tREF_NAME\tORIG_REF_NAME\tORIG_CELL_NAME\tPARENT"
foreach cell [lsort [get_cells -hier -filter {IS_PRIMITIVE == 0}]] {
    set properties [list_property $cell]
    set row {}
    foreach property {NAME REF_NAME ORIG_REF_NAME ORIG_CELL_NAME PARENT} {
        if {[lsearch -exact $properties $property]>=0} {
            lappend row [get_property $property $cell]
        } else {
            lappend row {}
        }
    }
    puts $hierarchyfh [join $row "\t"]
}
close $hierarchyfh
set clockfh [open $out/clock_cells.txt w]
foreach cell [lsort [get_cells -hier -filter {REF_NAME =~ MMCME* || REF_NAME =~ BUFG*}]] {
    puts $clockfh "[get_property REF_NAME $cell] $cell"
}
close $clockfh
report_utilization -file $out/utilization_synth.txt
report_utilization -hierarchical -file $out/utilization_synth_hier.txt
report_timing_summary -delay_type min_max -report_unconstrained -file $out/timing_synth.txt
report_timing -delay_type max -max_paths 20 -file $out/setup_synth_paths.txt
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 20 -file $out/internal_setup_synth_paths.txt
set memfh [open $out/memory_mapping.txt w]
foreach stem {features weight_q lut_a lut_b} {
    set mapped [get_cells -hier -filter "REF_NAME =~ RAMB* && NAME =~ *${stem}*"]
    puts $memfh "$stem [llength $mapped]"
}
close $memfh
# A LUTRAM fallback is not an acceptable physical version of this datapath.
if {[llength [get_cells -hier -filter {REF_NAME =~ RAMB* && NAME =~ *features*}]] == 0} {
    error "Feature storage did not infer block RAM; reject this implementation"
}
set cellsfh [open $out/mapped_ram_dsp_cells.txt w]
foreach cell [lsort [get_cells -hier -filter {REF_NAME =~ RAMB* || REF_NAME =~ DSP48*}]] {
    puts $cellsfh "[get_property REF_NAME $cell] $cell"
}
close $cellsfh
write_checkpoint -force $out/synth.dcp
d4_report_endpoint_groups $out synth
if {$mode eq "synth"} { exit }
# Input jitter is ignored during synthesis; reapply it for implementation.
set_input_jitter [get_clocks physical_clk] 0.050
if {abs([get_property INPUT_JITTER [get_clocks physical_clk]]-0.050)>0.0001} {
    error "Implementation INPUT_JITTER must remain 0.050 ns"
}
opt_design
place_design -directive Explore
report_timing_summary -delay_type min_max -file $out/timing_post_place.txt
report_timing -delay_type max -max_paths 20 -file $out/setup_post_place_paths.txt
phys_opt_design -directive Explore
report_timing -delay_type max -max_paths 20 -file $out/setup_post_physopt_paths.txt
write_checkpoint -force $out/placed_physopt.dcp
route_design -directive Explore
report_route_status -file $out/route_status.txt
report_utilization -hierarchical -file $out/utilization_post_route.txt
report_timing_summary -delay_type min_max -report_unconstrained -file $out/timing_post_route.txt
report_timing -delay_type max -max_paths 20 -file $out/setup_paths.txt
report_timing -delay_type min -max_paths 10 -file $out/hold_paths.txt
d4_report_endpoint_groups $out post_route
report_drc -file $out/drc.txt
report_power -file $out/power_vectorless.txt
write_checkpoint -force $out/routed.dcp
set fh [open $out/evidence_scope.txt w]
puts $fh "part=xc7z020clg400-1"
puts $fh "scope=full D4 datapath; parallel streaming prototype; no board or CPU integration"
puts $fh "clock_period_ns=8.000"
puts $fh "power_activity=vectorless screening only; activity-based power remains required"
puts $fh "weights=resident ROM; image transfer included in RTL start-to-done cycles"
close $fh
exit
