# Query the routed runner-only checkpoint for the tiled-input row-base cone.
# The checkpoint is produced by vivado_cnn_layer_runner_tiled_store_recurrence_20260827.tcl
# with RUNNER_OOC_PERIOD=10 and RUNNER_OOC_OUT set to the candidate directory.
set root [file normalize [file join [file dirname [info script]] ..]]
set run_dir [file normalize [file join $root build reports vivado_cnn_layer_runner_rowbase_recurrence_10ns_20260828]]
open_checkpoint [file join $run_dir cnn_layer_runner_tiled_store_recurrence_10ns_post_route.dcp]
set from [get_pins -hierarchical *tiled_input_row_stride_reg*/C]
set to [get_pins -hierarchical *tiled_input_index_reg_reg*/D]
set f [open [file join $run_dir rowbase_target_cone.txt] w]
puts $f "from_count=[llength $from] to_count=[llength $to]"
if {[llength $from] > 0 && [llength $to] > 0} {
    set paths [get_timing_paths -delay_type max -from $from -to $to -max_paths 20 -nworst 20 -sort_by slack]
    puts $f "path_count=[llength $paths]"
    report_timing -delay_type max -from $from -to $to -max_paths 20 -nworst 20 \
        -sort_by slack -path_type full -input_pins -nets -file [file join $run_dir rowbase_target_cone_maxpaths.txt]
} else {
    puts $f "path_count=0"
}
close $f
exit
