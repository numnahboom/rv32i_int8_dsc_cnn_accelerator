# Continue the retained-only OOC flow from the completed synthesized DCP.
# Kept as a bounded implementation proof helper for the tiled-loader slice.
set out [file normalize [lindex $argv 0]]
set xdc [file normalize "constraints/cnn_top_unified64_ooc_8ns.xdc"]
set_param general.maxThreads 8
open_checkpoint [file join $out cnn_top_synth.dcp]
read_xdc -quiet $xdc
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
report_timing_summary -delay_type max -report_unconstrained -file [file join $out timing_summary_continue.txt]
report_timing -delay_type max -max_paths 20 -file [file join $out timing_maxpaths_continue.txt]
report_timing -delay_type min -max_paths 20 -file [file join $out timing_minpaths_continue.txt]
report_utilization -file [file join $out utilization_post_route_continue.txt]
report_route_status -file [file join $out route_status_continue.txt]
write_checkpoint -force [file join $out cnn_top_tiled_lookahead_ooc_post_route.dcp]
exit
