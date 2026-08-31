# Query the tiled external-load request-enable cone in a routed runner DCP.
set root [file normalize [file join [file dirname [info script]] ..]]
set dcp [file normalize [file join $root build reports vivado_cnn_layer_runner_tiled_load_req_enable_20260828 cnn_layer_runner_tiled_store_recurrence_10ns_post_route.dcp]]
set out [file normalize [file join $root build reports vivado_cnn_layer_runner_tiled_load_req_enable_20260828]]
open_checkpoint $dcp
set from [get_pins -hierarchical *tiled_load_channel_reg*/C]
set to_ce [get_pins -hierarchical *mem_req_addr_reg*/CE]
set to_d [get_pins -hierarchical *mem_req_addr_reg*/D]
set f [open [file join $out tiled_load_channel_to_mem_req_addr.txt] w]
puts $f "from_count=[llength $from] to_ce_count=[llength $to_ce] to_d_count=[llength $to_d]"
foreach {name to} [list ce $to_ce d $to_d] {
    set paths [get_timing_paths -delay_type max -from $from -to $to -max_paths 200 -nworst 200 -sort_by slack]
    puts $f "${name}_path_count=[llength $paths]"
    if {[llength $paths] > 0} {
        set worst [lindex $paths 0]
        puts $f "${name}_worst_slack=[get_property SLACK $worst]"
        puts $f "${name}_worst_delay=[get_property DATAPATH_DELAY $worst]"
        puts $f "${name}_worst_start=[get_property STARTPOINT_PIN $worst]"
        puts $f "${name}_worst_end=[get_property ENDPOINT_PIN $worst]"
        report_timing -delay_type max -from $from -to $to -max_paths 20 -nworst 20 \
            -sort_by slack -path_type full -input_pins -nets \
            -file [file join $out tiled_load_channel_to_mem_req_addr_${name}.rpt]
    }
}
close $f
exit
