# Read-only post-synthesis accounting for the retained-DS1 full-top run.
if {[llength $argv] != 2} {
    error "usage: vivado -mode batch -source vivado_query_retained_fulltop_synth_20260901.tcl -tclargs <dcp> <out>"
}
set dcp [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
file mkdir $out
open_checkpoint $dcp
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $out utilization_hierarchical_synth.txt]
catch {report_power -file [file join $out power_synth_estimate.txt]}
catch {report_timing_summary -delay_type min_max -max_paths 20 -report_unconstrained -file [file join $out timing_synth_summary.txt]}
close_design
exit
