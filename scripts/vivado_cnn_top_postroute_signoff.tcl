# Generate signoff-only reports from an already routed cnn_top checkpoint.
# This is intentionally read-only with respect to placement/routing; it is
# used when the main implementation flow stops at its expected negative
# timing result after writing the post-route DCP.
if {[llength $argv] < 2} {
    error "usage: vivado -mode batch -source vivado_cnn_top_postroute_signoff.tcl -tclargs <impl.dcp> <out-dir>"
}
proc host_path {value} {
    return [file normalize [string map [list "\\" "/"] [string trim $value]]]
}
set dcp_file [host_path [lindex $argv 0]]
set out_dir [host_path [lindex $argv 1]]
file mkdir $out_dir
if {![file exists $dcp_file]} {
    error "missing routed checkpoint: $dcp_file"
}
open_checkpoint $dcp_file
set report_failures 0
set report_status_file [file join $out_dir postroute_signoff_status.txt]
set fh [open $report_status_file "w"]
puts $fh "format: cnn-top-postroute-signoff-v1"
puts $fh "checkpoint: $dcp_file"
puts $fh "design: [current_design]"
puts $fh "part: [get_property PART [current_design]]"
proc run_report {label command fh} {
    upvar 1 report_failures report_failures
    set rc [catch {uplevel 1 $command} message]
    if {$rc == 0} {
        puts $fh "${label}: PASSED"
    } else {
        set report_failures 1
        puts $fh "${label}: FAILED: [string map [list "\n" " | " "\r" ""] $message]"
    }
}
run_report clocks [list report_clocks -file [file join $out_dir clocks_post_route.txt]] $fh
run_report drc [list report_drc -file [file join $out_dir drc_post_route.txt]] $fh
run_report methodology [list report_methodology -file [file join $out_dir methodology_post_route.txt]] $fh
run_report congestion [list report_design_analysis -congestion -file [file join $out_dir congestion_post_route.txt]] $fh
run_report route_status [list report_route_status -file [file join $out_dir route_status_postroute_signoff.txt]] $fh
run_report timing_summary [list report_timing_summary -delay_type min_max -max_paths 20 -report_unconstrained -check_timing_verbose -file [file join $out_dir timing_summary_postroute_signoff.txt]] $fh
close $fh
if {$report_failures} {
    error "post-route signoff report generation failed; inspect $report_status_file"
}
puts "Post-route signoff reports completed: $out_dir"
