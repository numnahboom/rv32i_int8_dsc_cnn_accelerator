set root [file normalize [file join [file dirname [info script]] ..]]
set run_dir [file normalize [file join $root build reports vivado_cnn_layer_runner_store_eligibility_20260828]]
open_checkpoint [file join $run_dir cnn_layer_runner_tiled_store_recurrence_10ns_post_route.dcp]
set from [get_pins -hierarchical *store_channel_pos_reg*/C]
set en [get_pins -hierarchical *u_output_memory*/enb]
set f [open [file join $run_dir store_eligibility_cone.txt] w]
puts $f "from_count=[llength $from] en_count=[llength $en]"
if {[llength $from] > 0 && [llength $en] > 0} {
    set paths [get_timing_paths -delay_type max -from $from -to $en -max_paths 20 -nworst 20 -sort_by slack]
    puts $f "path_count=[llength $paths]"
    report_timing -delay_type max -from $from -to $en -max_paths 20 -nworst 20 \
        -sort_by slack -path_type full -input_pins -nets -file [file join $run_dir store_eligibility_cone_maxpaths.txt]
} else {
    puts $f "path_count=0"
}
close $f
exit
