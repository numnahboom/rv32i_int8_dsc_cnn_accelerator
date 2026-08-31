# Inspect the descriptor phase-count pipeline in the routed runner DCP.
set root [file normalize [file join [file dirname [info script]] ..]]
set run_dir vivado_cnn_layer_runner_phase_count_pipeline_20260828
set dcp_name cnn_layer_runner_tiled_store_recurrence_8ns_post_route.dcp
if {[info exists ::env(RUNNER_PHASE_COUNT_DCP)]} {
    set dcp [file normalize $::env(RUNNER_PHASE_COUNT_DCP)]
    set out [file dirname $dcp]
} else {
    set dcp [file normalize [file join $root build reports $run_dir $dcp_name]]
    set out [file normalize [file join $root build reports $run_dir]]
}
open_checkpoint $dcp
proc d_pins_for_cells {cells} {
    set result [list]
    foreach c $cells {
        foreach p [get_pins -of_objects $c] {
            if {[get_property REF_PIN_NAME $p] eq "D"} { lappend result $p }
        }
    }
    return $result
}
set phase_seed [d_pins_for_cells [get_cells -hierarchical *phase_count_seed_reg*]]
set phase_count [d_pins_for_cells [get_cells -hierarchical *phase_count_reg*]]
set span_seed [d_pins_for_cells [get_cells -hierarchical *sram_input_count_seed_reg*]]
set span_seed16 [d_pins_for_cells [get_cells -hierarchical *sram_input_count_seed16_reg*]]
set span_factor16 [d_pins_for_cells [get_cells -hierarchical *sram_input_count_factor16_reg*]]
set span_count [d_pins_for_cells [get_cells -hierarchical *sram_input_count_reg*]]
set f [open [file join $out phase_count_pipeline_paths.txt] w]
puts $f "phase_cells=[join [get_cells -hierarchical *phase_count*] { }]"
puts $f "span_cells=[join [get_cells -hierarchical *sram_input_count*] { }]"
puts $f "phase_seed_count=[llength $phase_seed] phase_count_count=[llength $phase_count]"
puts $f "span_seed_count=[llength $span_seed] span_seed16_count=[llength $span_seed16] span_factor16_count=[llength $span_factor16] span_count_count=[llength $span_count]"
foreach {name from to} [list phase_seed_to_count $phase_seed $phase_count span_seed_to_count $span_seed $span_count span_seed16_to_count $span_seed16 $span_count span_factor16_to_count $span_factor16 $span_count] {
    if {[llength $from] == 0 || [llength $to] == 0} {
        puts $f "${name}_path_count=0 (endpoint optimized or absent)"
        continue
    }
    set paths [get_timing_paths -delay_type max -from $from -to $to -max_paths 20 -nworst 20 -sort_by slack]
    puts $f "${name}_path_count=[llength $paths]"
    if {[llength $paths] > 0} {
        set worst [lindex $paths 0]
        puts $f "${name}_worst_slack=[get_property SLACK $worst]"
        puts $f "${name}_worst_delay=[get_property DATAPATH_DELAY $worst]"
        puts $f "${name}_worst_start=[get_property STARTPOINT_PIN $worst]"
        puts $f "${name}_worst_end=[get_property ENDPOINT_PIN $worst]"
        report_timing -delay_type max -from $from -to $to -max_paths 20 -nworst 20 \
            -sort_by slack -path_type full -input_pins -nets \
            -file [file join $out ${name}.rpt]
    }
}
# Also retain the worst incoming path to each destination register.  Synthesis
# may absorb the explicitly named seed register while preserving the staged
# product boundary, so this is the robust sign-off query for the endpoint.
foreach {name to} [list phase_count_incoming $phase_count span_count_incoming $span_count] {
    if {[llength $to] == 0} {
        puts $f "${name}_path_count=0 (endpoint optimized or absent)"
        continue
    }
    set paths [get_timing_paths -delay_type max -from [all_registers] -to $to \
        -max_paths 20 -nworst 20 -sort_by slack]
    puts $f "${name}_path_count=[llength $paths]"
    if {[llength $paths] > 0} {
        set worst [lindex $paths 0]
        puts $f "${name}_worst_slack=[get_property SLACK $worst]"
        puts $f "${name}_worst_delay=[get_property DATAPATH_DELAY $worst]"
        puts $f "${name}_worst_start=[get_property STARTPOINT_PIN $worst]"
        puts $f "${name}_worst_end=[get_property ENDPOINT_PIN $worst]"
        report_timing -delay_type max -from [all_registers] -to $to \
            -max_paths 20 -nworst 20 -sort_by slack -path_type full \
            -input_pins -nets -file [file join $out ${name}.rpt]
    }
}
close $f
exit
