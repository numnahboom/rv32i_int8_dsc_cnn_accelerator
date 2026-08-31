# Query the runner-only checkpoint for the descriptor opcode -> tiled FSM path.
set root [file normalize [file join [file dirname [info script]] ..]]
set out_name vivado_cnn_layer_runner_fsm_optype_decode_20260828
if {[info exists ::env(RUNNER_QUERY_OUT)]} { set out_name $::env(RUNNER_QUERY_OUT) }
set out [file normalize [file join $root build reports $out_name]]
open_checkpoint [file join $out cnn_layer_runner_tiled_store_recurrence_10ns_post_route.dcp]
write_verilog -force [file join $out cnn_layer_runner_fsm_optype_decode_post_route.v]

set from [get_pins -hierarchical *op_type_reg*/C]
set to [get_pins -hierarchical *FSM_onehot_state_reg\[21\]/D]
set f [open [file join $out fsm_optype_decode_paths.txt] w]
puts $f "from_count=[llength $from] to_count=[llength $to]"
if {[llength $from] > 0 && [llength $to] > 0} {
    set paths [get_timing_paths -delay_type max -from $from -to $to \
        -max_paths 20 -nworst 20 -sort_by slack]
    puts $f "path_count=[llength $paths]"
    if {[llength $paths] > 0} {
        set worst [lindex $paths 0]
        puts $f "worst_slack=[get_property SLACK $worst]"
        puts $f "worst_delay=[get_property DATAPATH_DELAY $worst]"
        puts $f "worst_start=[get_property STARTPOINT_PIN $worst]"
        puts $f "worst_end=[get_property ENDPOINT_PIN $worst]"
        report_timing -delay_type max -from $from -to $to -max_paths 20 \
            -nworst 20 -sort_by slack -path_type full -input_pins -nets \
            -file [file join $out fsm_optype_decode_paths.rpt]
    }
}
close $f
exit
